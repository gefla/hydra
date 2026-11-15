use strict;
use warnings;
use utf8;
use Setup;
use Test2::V0;
use HTTP::Request::Common;
use Digest::SHA qw(sha256_hex);
use URI;
use Hydra::Session::Store::DB;

my $ctx = test_context();
setup_catalyst_test($ctx);

# The store only needs `model('DB')`, but taking a context off a real request
# keeps this test on the wiring the web application uses.
my ($res, $c) = ctx_request(GET '/');
ok($res->is_success, "The application renders a page");

my $dbh = $c->model('DB')->schema->storage->dbh;

sub store_session_data { Hydra::Session::Store::DB::store_session_data($c, @_) }
sub get_session_data { Hydra::Session::Store::DB::get_session_data($c, $_[0]) }
sub delete_session_data { Hydra::Session::Store::DB::delete_session_data($c, @_) }

sub row {
    my ($id) = @_;
    return $dbh->selectrow_hashref("select * from Sessions where id = ?", {}, sha256_hex($id));
}

# A well-formed session cookie value: 40 lowercase hex characters.
my $sid = "ab3f" x 10;

subtest "the session hash is stored as JSON under the id's digest" => sub {
    my $data = {
        __user => { username => 'alice' },
        __user_realm => 'dbic',
        __created => 1000,
        __updated => 2000,
        referer => 'http://localhost/',
    };
    store_session_data("session:$sid", $data);

    is(get_session_data("session:$sid"), $data, "the session round-trips");
    is($dbh->selectrow_array("select data->>'referer' from Sessions where id = ?", {}, sha256_hex($sid)),
        'http://localhost/', "and SQL can read single keys of it");
    is($dbh->selectrow_array("select count(*) from Sessions where id = ?", {}, $sid), 0,
        "no row is keyed by the cookie value itself");
    is($dbh->selectrow_array("select id from Sessions where id = ?", {}, sha256_hex($sid)),
        sha256_hex($sid), "the row is keyed by the cookie value's SHA-256");
};

subtest "the expiry is never lowered" => sub {
    my $id = "11" x 20;

    store_session_data("expires:$id", 1000);
    is(get_session_data("expires:$id"), 1000, "the first write sets the expiry");

    store_session_data("expires:$id", 900);
    is(get_session_data("expires:$id"), 1000, "a smaller expiry does not shorten the session");

    store_session_data("expires:$id", 5000);
    is(get_session_data("expires:$id"), 5000, "a larger expiry is taken");
};

subtest "a half-written or absent row is not a session" => sub {
    my $half = "cd" x 20;
    # The expiry half can arrive first, as it does while a session is being
    # created; the row then exists with null data.
    store_session_data("expires:$half", 4102444800);
    ok(defined row($half), "the row exists");
    is(get_session_data("session:$half"), undef, "but there is no session data in it");

    my $unknown = "ef" x 20;
    is(get_session_data("expires:$unknown"), 0, "an id with no row has expiry 0");
    is(get_session_data("session:$unknown"), undef, "and no data");
};

subtest "flash is not stored, and deleting it is a no-op" => sub {
    my $id = "77" x 20;
    store_session_data("session:$id", { a => 1 });
    is(get_session_data("flash:$id"), undef, "there is nothing to read under the flash prefix");

    delete_session_data("flash:$id");
    ok(defined row($id), "deleting the flash leaves the session row alone");

    like(dies { store_session_data("flash:$id", { a => 1 }) },
        qr/not storable/,
        "storing flash is refused rather than silently dropped");
};

subtest "deleting either half removes the row" => sub {
    my $id = "44" x 20;

    store_session_data("session:$id", { a => 1 });
    store_session_data("expires:$id", 4102444800);
    delete_session_data("session:$id");
    is(get_session_data("session:$id"), undef, "the data is gone");
    is(get_session_data("expires:$id"), 0, "so is the expiry, and the row went with it");
    ok(!defined row($id), "no row is left");

    store_session_data("session:$id", { a => 1 });
    store_session_data("expires:$id", 4102444800);
    delete_session_data("expires:$id");
    ok(!defined row($id), "deleting through the expiry removes the row too");
};

subtest "an unknown key prefix is refused" => sub {
    for my $key ("user:alice", ":alice", "sessions:$sid") {
        like(dies { store_session_data($key, {}) }, qr/prefix/, "storing `$key' is refused");
        like(dies { get_session_data($key) }, qr/prefix/, "reading `$key' is refused");
        like(dies { delete_session_data($key) }, qr/prefix/, "deleting `$key' is refused");
    }

    like(dies { store_session_data("session$sid", {}) },
        qr/invalid session key/,
        "a key without a prefix is refused");
};

subtest "a value that is still a Perl object fails" => sub {
    my $id = "22" x 20;
    store_session_data("session:$id", { referer => 'http://localhost/before' });

    like(dies { store_session_data("session:$id", { referer => URI->new('http://localhost/after') }) },
        qr/object|blessed/,
        "a URI in the session dies instead of being stored unreadably");

    is(get_session_data("session:$id")->{referer}, 'http://localhost/before',
        "and the stored session is untouched");
};

subtest "non-ASCII values survive as characters" => sub {
    my $id = "33" x 20;
    my $name = "ålice";

    store_session_data("session:$id", { __user => { username => $name } });

    is(get_session_data("session:$id")->{__user}{username}, $name,
        "the value comes back unchanged");
    is($dbh->selectrow_array("select data->'__user'->>'username' from Sessions where id = ?", {}, sha256_hex($id)),
        $name, "and SQL sees the same text");
    is($dbh->selectrow_array("select octet_length(data->'__user'->>'username') from Sessions where id = ?", {}, sha256_hex($id)),
        6, "the database holds UTF-8 (6 bytes), not double-encoded bytes");
};

subtest "creating a session purges expired rows" => sub {
    my $expired = "55" x 20;
    my $alive = "66" x 20;

    store_session_data("expires:$expired", time - 1);
    store_session_data("expires:$alive", time + 60);

    my $created = $c->create_session_id;
    ok(defined $created && $created =~ /^[0-9a-f]{40}$/, "a session id was created");

    ok(!defined row($expired), "the expired row is gone");
    ok(defined row($alive), "the live row is not");
};

done_testing;
