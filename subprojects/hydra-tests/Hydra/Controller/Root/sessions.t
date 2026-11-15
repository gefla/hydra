use strict;
use warnings;
use Setup;
use Test2::V0;
use HTTP::Request::Common;
use Digest::SHA qw(sha256_hex);
use HTTP::Date qw(str2time);
use DBI;

# Web sessions live in the `Sessions` table (see the session-storage spec), so
# that any Hydra web component sharing the database recognises the same
# signed-in users. These are the cases that need a real request: what a browser
# or another component sees, rather than what the store returns in isolation
# (that is Hydra/Session/Store.t).

my $ctx = test_context(hydra_config => <<'CFG');
    <oidc>
        <provider authentik>
            display_name = "Authentik"
            authorization_endpoint = "https://authentik.example.com/authorize"
            token_endpoint = "https://authentik.example.com/token"
            jwks_uri = "https://authentik.example.com/certs"
            issuer = "https://authentik.example.com"
            client_id = "hydra"
            client_secret = "hunter2"
        </provider>
    </oidc>
CFG
setup_catalyst_test($ctx);

my $dbh = $ctx->db->storage->dbh;

my $alice = $ctx->db->resultset('Users')->create({
    username => 'alice',
    emailaddress => 'alice@example.com',
    password => '!'
});
$alice->setPassword('foobar');

my $nr_sessions = sub { scalar $dbh->selectrow_array("select count(*) from Sessions") };

sub nr_rows_for {
    my ($cookie) = @_;
    return scalar $dbh->selectrow_array("select count(*) from Sessions where id = ?", {}, sha256_hex($cookie));
}

sub expires_of {
    my ($cookie) = @_;
    return $dbh->selectrow_array("select expires from Sessions where id = ?", {}, sha256_hex($cookie));
}

sub data_key {
    my ($cookie, $key) = @_;
    return $dbh->selectrow_array("select data->>'$key' from Sessions where id = ?", {}, sha256_hex($cookie));
}

sub jsonb_type_of {
    my ($cookie, $key) = @_;
    return $dbh->selectrow_array("select jsonb_typeof(data->'$key') from Sessions where id = ?", {}, sha256_hex($cookie));
}

sub has_key {
    my ($cookie, $key) = @_;
    return $dbh->selectrow_array(
        "select (data->'$key' is not null)::int from Sessions where id = ?", {}, sha256_hex($cookie));
}

# The rendered Set-Cookie for the session cookie, sliced out of the header.
sub session_cookie {
    my ($res) = @_;
    my $set = $res->header('Set-Cookie');
    return undef unless defined $set;
    my @cookies = ref $set eq 'ARRAY' ? @$set : ($set);
    for my $cookie (@cookies) {
        next unless $cookie =~ /(hydra_session=.*)/s;
        my $session = $1;
        # Drop a following cookie, if the header carried more than one.
        $session =~ s/,\s*(?=[A-Za-z0-9_.-]+=).*//s;
        return $session;
    }
    return undef;
}

sub session_id_from {
    my ($res) = @_;
    my $cookie = session_cookie($res) or return undef;
    my ($value) = $cookie =~ /^hydra_session=([0-9a-f]{40})/;
    return $value;
}

sub get_as {
    my ($path, $cookie) = @_;
    return request(GET $path, Cookie => "hydra_session=$cookie");
}

# /current-user is a REST action: it only describes the user when JSON is asked
# for, and otherwise falls back to a page template.
sub current_user {
    my ($cookie) = @_;
    return request(GET '/current-user', Cookie => "hydra_session=$cookie", Accept => 'application/json');
}

# Sign in with a password. Returns the response and the session id it issues.
sub sign_in {
    my ($cookie) = @_;
    my ($res) = ctx_request(POST '/login',
        (defined $cookie ? (Cookie => "hydra_session=$cookie") : ()),
        Referer => 'http://localhost/',
        Content => { username => 'alice', password => 'foobar' });
    return ($res, session_id_from($res));
}

subtest "a cookieless page view creates no session" => sub {
    for my $path ('/', '/queue') {
        my $before = $nr_sessions->();
        my $response = request(GET $path);

        ok($response->is_success, "`$path' renders");
        is(session_cookie($response), undef, "`$path' sets no hydra_session cookie");
        is($nr_sessions->(), $before, "`$path' adds no row");
    }
};

subtest "an unknown session id creates no row" => sub {
    my $unknown = "ab" x 20;

    my $before = $nr_sessions->();
    my $response = request(GET '/', Cookie => "hydra_session=$unknown");

    ok($response->is_success, "the page renders");
    is($nr_sessions->(), $before, "no row was created for it");
};

subtest "starting an OIDC login creates a session" => sub {
    my $before = $nr_sessions->();
    my $response = request(GET '/oidc-redirect/authentik');

    is($response->code, 302, "the redirect to the provider happens");
    like($response->header('Location'), qr{^https://authentik\.example\.com/authorize},
        "and goes to the provider");

    my $cookie = session_id_from($response);
    ok(defined $cookie, "a session id was issued");

    if (defined $cookie) {
        is($nr_sessions->(), $before + 1, "the session was stored");
        is(jsonb_type_of($cookie, 'oidc'), 'object', "the login state is in the row");
        is($dbh->selectrow_array("select data->'oidc'->>'provider_name' from Sessions where id = ?", {}, sha256_hex($cookie)),
            'authentik', "for the provider that was asked for");
    }
};

subtest "signing in stores the session before the response arrives" => sub {
    # A second connection, open before the response is read: it can only see
    # the row if the web application committed it before replying. Another web
    # component may immediately use the cookie it was just handed.
    my $other = DBI->connect($ctx->{db_handle}->dsn, '', '', { RaiseError => 1, PrintError => 0 });
    ok($other, "a second connection is open");

    my ($response, $cookie) = sign_in();
    is($response->code, 302, "signing in redirects");
    like($response->header('Location'), qr{/current-user$}, "to the user's own page");
    like($cookie // '', qr/^[0-9a-f]{40}$/, "the session id is 40 lowercase hex characters");

    my ($row) = $other->selectrow_array("select data from Sessions where id = ?", {}, sha256_hex($cookie));
    ok(defined $row, "the other connection sees the row");
    is($other->selectrow_array("select data->'__user'->>'username' from Sessions where id = ?", {}, sha256_hex($cookie)),
        'alice', "it names the user");
    is($other->selectrow_array("select data->>'__user_realm' from Sessions where id = ?", {}, sha256_hex($cookie)),
        'dbic', "in the dbic realm");
    is($other->selectrow_array("select jsonb_typeof(data->'__created') from Sessions where id = ?", {}, sha256_hex($cookie)),
        'number', "__created is a number");
    is($other->selectrow_array("select jsonb_typeof(data->'__updated') from Sessions where id = ?", {}, sha256_hex($cookie)),
        'number', "__updated is a number");
    ok($other->selectrow_array("select (data->>'__created')::int > 0 from Sessions where id = ?", {}, sha256_hex($cookie)),
        "__created is an epoch second");
    is(nr_rows_for($cookie), 1, "and no row is keyed by the cookie value itself");

    my $me = current_user($cookie);
    like($me->content, qr/"username"\s*:\s*"alice"/, "the session describes the user");

    $other->disconnect;
};

subtest "the session cookie has the documented attributes" => sub {
    my ($response, $cookie) = sign_in();
    my $header = session_cookie($response) // '';

    like($header, qr/^hydra_session=[0-9a-f]{40}/, "the cookie is named hydra_session and carries the id");
    like($header, qr/;\s*path=\//i, "it is scoped to /");
    like($header, qr/;\s*httponly/i, "it is HttpOnly");
    like($header, qr/;\s*samesite=lax/i, "it is SameSite=Lax");

    my ($expires) = $header =~ /;\s*expires=([^;]+)/i;
    ok(defined $expires, "it has an expiry");
    is(str2time($expires), expires_of($cookie), "which is the session's expiry");
};

subtest "a row written by another component is honoured" => sub {
    my $cookie = "0123456789abcdef0123456789abcdef01234567";
    $dbh->do("insert into Sessions (id, data, expires) values (?, ?, ?)", {}, sha256_hex($cookie),
        '{"__user":{"username":"alice"},"__user_realm":"dbic","__created":1,"__updated":1}',
        time + 60);

    my $response = current_user($cookie);
    ok($response->is_success, "the request is treated as signed in");
    like($response->content, qr/"username"\s*:\s*"alice"/, "as the user alice");

    ok(expires_of($cookie) >= time + 604800, "and the session was extended by at least seven days");
};

subtest "expired, data-less and user-less rows are not sessions" => sub {
    my $expired = "11" x 20;
    $dbh->do("insert into Sessions (id, data, expires) values (?, ?, ?)", {}, sha256_hex($expired),
        '{"__user":{"username":"alice"},"__user_realm":"dbic","__created":1,"__updated":1}', time - 1);

    my $data_less = "22" x 20;
    $dbh->do("insert into Sessions (id, data, expires) values (?, null, ?)", {}, sha256_hex($data_less), time + 3600);

    my $user_less = "33" x 20;
    $dbh->do("insert into Sessions (id, data, expires) values (?, ?, ?)", {}, sha256_hex($user_less),
        '{"referer":"http://localhost/queue"}', time + 3600);

    for my $case (["an expired row", $expired], ["a row with no data", $data_less], ["a row with no user", $user_less]) {
        my ($what, $cookie) = @$case;
        my $response = current_user($cookie);
        is($response->code, 403, "$what is not signed in");
    }
};

subtest "a flash written by another component is shown once" => sub {
    my ($login, $cookie) = sign_in();
    is($login->code, 302, "signed in");

    # The other component rewrites the row, keeping the keys it does not own.
    $dbh->do("update Sessions set data = ?::jsonb where id = ?", {},
        '{"__user":{"username":"alice"},"__user_realm":"dbic","__created":1,"__updated":1,"__flash":{"flashMsg":"Hello from another component"},"oidc_provider":"authentik"}',
        sha256_hex($cookie));

    my $first = get_as('/', $cookie);
    like($first->content, qr/Hello from another component/, "the message is shown");

    my $second = get_as('/', $cookie);
    unlike($second->content, qr/Hello from another component/, "and only once");

    is(data_key($cookie, 'oidc_provider'), 'authentik', "the key the other component kept is still there");
};

subtest "POST sign-out keeps the row for the flash message" => sub {
    my ($login, $cookie) = sign_in();
    is($login->code, 302, "signed in");

    my $response = request(POST '/logout',
        Cookie => "hydra_session=$cookie",
        Referer => 'http://localhost/',
    );
    is($response->code, 204, "the sign-out is accepted");

    is(has_key($cookie, '__user'), 0, "the row no longer has a user");
    is(has_key($cookie, '__user_realm'), 0, "nor a realm");
    ok(defined $dbh->selectrow_array("select 1 from Sessions where id = ?", {}, sha256_hex($cookie)),
        "but the row is kept");

    # Read the flash before any other page: reading it is what consumes it.
    my $page = get_as('/', $cookie);
    like($page->content, qr/You are no longer signed in/, "the sign-out message is shown");

    my $signed_out = current_user($cookie);
    is($signed_out->code, 403, "and the session is not signed in");
};

subtest "GET sign-out with a token deletes the row and expires the cookie" => sub {
    my ($login, $cookie) = sign_in();
    is($login->code, 302, "signed in");

    my $token = sha256_hex($cookie . ":logout");
    my $response = get_as("/logout?token=$token", $cookie);
    is($response->code, 302, "the sign-out redirects");

    is(nr_rows_for($cookie), 0, "the row is gone");

    my $header = session_cookie($response);
    ok(defined $header, "the response touches the session cookie");
    my ($expires) = ($header // '') =~ /;\s*expires=([^;]+)/i;
    ok(defined $expires && str2time($expires) <= time(), "and expires it");
};

subtest "a stale cookie is anonymous and can sign in again" => sub {
    # Stands in for a session cookie issued by the old file-based store.
    my $stale = "fe" x 20;
    is(nr_rows_for($stale), 0, "no row matches it");

    my $anonymous = current_user($stale);
    is($anonymous->code, 403, "the request is anonymous");

    my ($login, $cookie) = sign_in();
    is($login->code, 302, "it can sign in again");
    isnt($cookie, $stale, "with a new session id");

    my $me = current_user($cookie);
    like($me->content, qr/"username"\s*:\s*"alice"/, "and the session describes the user");
};

subtest "a flash set by a writer is shown once and then gone" => sub {
    my ($login, $cookie) = sign_in();
    is($login->code, 302, "signed in");

    # POST /logout is one of the writers: it records the message in the flash.
    request(POST '/logout', Cookie => "hydra_session=$cookie", Referer => 'http://localhost/');

    my $first = get_as('/', $cookie);
    like($first->content, qr/You are no longer signed in/, "the message is shown once");

    my $second = get_as('/', $cookie);
    unlike($second->content, qr/You are no longer signed in/, "and is gone on the following request");
};

subtest "the URL that required sign-in is stored as a string" => sub {
    my $config = Hydra->config;
    local $config->{private} = "1";

    my $response = request(GET '/status');
    is($response->code, 403, "a private Hydra refuses an anonymous request");

    my $cookie = session_id_from($response);
    ok(defined $cookie, "and creates a session for the sign-in that must follow");

    if (defined $cookie) {
        is(jsonb_type_of($cookie, 'referer'), 'string', "the URL is a JSON string");
        is(data_key($cookie, 'referer'), 'http://localhost/status', "and it is the page that was asked for");

        # Signing in rotates the session id (Catalyst's authentication realm
        # does that to prevent fixation), so the URL has to be carried over to
        # the new row for the user to get back to the page they asked for.
        my ($login, $newcookie) = sign_in($cookie);
        is($login->code, 302, "signing in succeeds");
        ok(defined $newcookie, "and issues a session of its own");
        is(nr_rows_for($cookie), 0, "the anonymous session's row is gone");
        is(data_key($newcookie, 'referer'), 'http://localhost/status',
            "and the URL it held moved to the new session");

        my $after = get_as('/status', $newcookie);
        is($after->code, 200, "the page that required sign-in renders now");
    }
};

done_testing;
