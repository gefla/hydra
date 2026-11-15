package Hydra::Session::Store::DB;

use utf8;
use strict;
use warnings;

use Catalyst::Exception;
use Digest::SHA qw(sha256_hex);
use JSON::MaybeXS;
use parent 'Catalyst::Plugin::Session::Store';

=head1 NAME

Hydra::Session::Store::DB - Catalyst session store kept in the Hydra database

=head1 DESCRIPTION

Keeps Hydra's web sessions in the C<Sessions> table, so that every Hydra web
component sharing the database recognises the same signed-in users. The row
contract (id derivation, data shape, expiry semantics) is specified in the
session-storage spec, F<openspec/specs/session-storage/spec.md>.

The keys are the ones L<Catalyst::Plugin::Session> uses: C<session:E<lt>idE<gt>>,
C<expires:E<lt>idE<gt>> and C<flash:E<lt>idE<gt>>. C<E<lt>idE<gt>> is the session
cookie value; every statement here keys the row by its SHA-256 digest instead,
so a copy of the table (or a backup, or a dump) holds no usable cookies.

=cut

# The encoder dies on a blessed reference unless it is told otherwise, which
# is what we want: a session value that is still a Perl object (C<referer>
# used to be a URI) must fail the request in testing rather than be stored as
# something no other component can read.
#
# `utf8 => 0` leaves the encoded string as characters. The column is jsonb and
# DBD::Pg has no C<pg_enable_utf8> set here, so handing it UTF-8 bytes would
# double-encode everything non-ASCII.
my $JSON = JSON::MaybeXS->new(utf8 => 0, allow_blessed => 0, convert_blessed => 0);

sub _dbh {
    my ($c) = @_;
    return $c->model('DB')->schema->storage->dbh;
}

# Split a Catalyst session key into its prefix and the session id.
sub _split_key {
    my ($key) = @_;
    my ($prefix, $id) = split /:/, $key, 2;
    Catalyst::Exception->throw("invalid session key `$key'") unless defined $id;
    return ($prefix, $id);
}

sub _unhandled {
    my ($prefix, $key) = @_;
    Catalyst::Exception->throw("unknown session key prefix `$prefix' in `$key'");
}

sub get_session_data {
    my ($c, $key) = @_;
    my ($prefix, $id) = _split_key($key);
    my $row_id = sha256_hex($id);

    if ($prefix eq "session") {
        my ($data) = _dbh($c)->selectrow_array("select data from Sessions where id = ?", {}, $row_id);
        # Either half of the session can create the row, so `data` may still be
        # null while a request is in flight; null is not a session.
        return undef unless defined $data;
        return $JSON->decode($data);
    } elsif ($prefix eq "expires") {
        my ($expires) = _dbh($c)->selectrow_array("select expires from Sessions where id = ?", {}, $row_id);
        return defined $expires ? $expires : 0;
    } elsif ($prefix eq "flash") {
        # Flash lives inside the session hash, as `__flash`.
        return undef;
    } else {
        _unhandled($prefix, $key);
    }
}

sub store_session_data {
    my ($c, $key, $data) = @_;
    my ($prefix, $id) = _split_key($key);
    my $row_id = sha256_hex($id);

    if ($prefix eq "session") {
        # One atomic statement: an update_or_create would be a select
        # followed by an insert, and two requests can lose each other's data
        # in between.
        _dbh($c)->do(
            "insert into Sessions (id, data) values (?, ?)"
            . " on conflict (id) do update set data = excluded.data",
            {}, $row_id, $JSON->encode($data));
    } elsif ($prefix eq "expires") {
        # `greatest` so that a slow concurrent request cannot pull the expiry
        # back in front of one that another request just extended.
        _dbh($c)->do(
            "insert into Sessions (id, expires) values (?, ?)"
            . " on conflict (id) do update set expires = greatest(Sessions.expires, excluded.expires)",
            {}, $row_id, $data);
    } elsif ($prefix eq "flash") {
        Catalyst::Exception->throw("`$key' is not storable: flash lives in the session hash");
    } else {
        _unhandled($prefix, $key);
    }
}

sub delete_session_data {
    my ($c, $key) = @_;
    my ($prefix, $id) = _split_key($key);

    if ($prefix eq "session" || $prefix eq "expires") {
        # Deleting on either one is safe: Catalyst issues all three deletes
        # together (delete_session, change_session_id), and a row without data
        # or without an expiry is not a session.
        _dbh($c)->do("delete from Sessions where id = ?", {}, sha256_hex($id));
    } elsif ($prefix eq "flash") {
        # Nothing is stored under this prefix.
    } else {
        _unhandled($prefix, $key);
    }
}

# Nothing evicts expired rows any more, so a new session clears them out.
# Deadlines are compared against Perl's clock, not the database's: expiries
# are computed here and the database may be on another host.
sub create_session_id {
    my ($c, @args) = @_;
    _dbh($c)->do("delete from Sessions where expires < ?", {}, time);
    return $c->maybe::next::method(@args);
}

1;
