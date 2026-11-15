# Design

## Context

See proposal.md for motivation and specs/session-storage/spec.md for the contract. Facts about the current system that shape the approach (from reading the code and the installed plugin sources; nothing here was run):

- `Hydra.pm` loads `Session`, `Session::Store::FastMmap` and `Session::State::Cookie` next to `Authentication` (realm `dbic`). Hydra sets no `verify_address`, no `verify_user_agent`, no `rotate_session_id`, no `expiry_threshold`, no `cookie_expires`.
- A store implements `get_session_data`, `store_session_data` and `delete_session_data` over keys of the form `session:<id>` (a hash), `expires:<id>` (an integer) and `flash:<id>`. Flash lives inside the session hash as `__flash`, so `flash:` is only ever deleted, never stored. A new session writes `expires:` in `finalize_headers` and `session:` in `finalize_body`.
- nixpkgs has no database-backed Catalyst session store (its `Session*` Perl packages are the plugin, `Store::FastMmap`, `Store::File` and the state plugins), so the store class is written here.
- `Hydra::Plugin` uses `Module::Pluggable` with `search_path => "Hydra::Plugin"` and instantiates everything it finds there. The store class must not live under `Hydra::Plugin::`.
- `hydra-server` requires `hydra-init.service`, which applies `sql/migrations/upgrade-N.sql` in order, so the table exists before the web app starts.

## Goals / Non-Goals

**Goals:**
- One store both Perl and a future Haskell service read and write, with a row format a non-Perl client can follow from the spec alone.
- No behavior change for signed-in users beyond the one-time sign-out.
- No unbounded table growth.

**Non-Goals:**
- Any Haskell code, nginx, or login flow.
- Changing how sessions are authenticated, rotated, or fixated. Hydra reuses the session id across sign-in today (it sets no `rotate_session_id`); that stays.
- Tuning write volume (see Risks).

## Decisions

### D1. Table shape and key

```sql
create table Sessions (
    id       text   primary key not null,        -- hex SHA-256 of the cookie value
    data     jsonb,                              -- Catalyst session hash; null until written
    expires  bigint not null default 0           -- epoch seconds; 0 = not yet recorded
);
create index IndexSessionsOnExpires on Sessions(expires);
```

- `data` is nullable and `expires` defaults to 0 because the two halves arrive in separate store calls. Either can insert the row first, and a half-written row is invalid (expired or no data) rather than a session.
- `bigint` follows migration 88, which moved every timestamp to 64 bits.
- The index serves the purge (D6).

Alternatives: *raw cookie value as `id`*: simplest to inspect, but any table read, backup or dump yields live admin cookies (decided against, see below). *Separate columns for user and realm*: duplicates `__user`, which must stay in `data` for Perl anyway.

### D2. `id` is the SHA-256 of the cookie value

The store computes `sha256_hex($sid)` (`Digest::SHA` is already a dependency; `CatalystUtils.pm` uses it) before every read, write and delete. Every other client must do the same, hence the spec requirement.

No salt or slow KDF: the preimage is 160 random bits, not a password, so brute force is not the threat; plain disclosure of the table is. As a side effect, lookups are index equality on a value the attacker cannot choose to match a secret.

### D3. Catalyst keys map onto columns

| Key prefix | `store_session_data` | `delete_session_data` | `get_session_data` |
|---|---|---|---|
| `session:` | upsert `data` | delete the row | `data` decoded, or nothing if null |
| `expires:` | upsert `expires`, never lowering it | delete the row | `expires` (0 if no row) |
| `flash:` | not used | no-op | nothing |
| anything else | die | die | die |

Dying on unknown prefixes surfaces a plugin such as `Session::PerUser` being added later, instead of losing its data silently. Deleting the row on either of the first two deletes is safe: Catalyst issues all three deletes together (`delete_session`, `change_session_id`).

`expires` is written as `greatest(Sessions.expires, excluded.expires)` so a slow concurrent request cannot shorten a session another request just extended. This also covers the spec's "never shortened".

Writes use `insert ... on conflict (id) do update` through the existing DBIC storage handle, not `update_or_create`, which is a select followed by an insert and therefore not atomic. The generated `Hydra::Schema::Result::Sessions` class is still required (`check-dbix-up-to-date` regenerates every class and diffs), and `sql/update-dbix.pl` needs a `sessions => "Sessions"` moniker entry or the generator names it `Session`.

### D4. `data` is `jsonb`, encoded so mistakes are loud

jsonb validates what is stored and lets another client edit single keys. The store encodes with a JSON encoder that dies on blessed references, so a session value that is still a Perl object (the `URI` in `referer`) fails the request in testing instead of being stored as something unreadable. `forceLogin` stringifies `referer` at assignment. The other non-trivial session values are already plain strings or numbers: OIDC `after` and `redirect_uri` use `->as_string`.

Alternative: `text` holding JSON. It avoids a column type `hydra.sql` does not use yet, but gives up validation and server-side key access for no gain.

### D5. Cookieless requests no longer create sessions

`Root::begin` and `Root::queue_GET` read `$c->flash`, which allocates a session id and, at finalize, writes both keys and sets a cookie. The reads move behind a small helper in `CatalystUtils.pm` that consults flash only when `$c->sessionid` is set and `$c->session_is_valid` is true. Writers (`$c->flash->{...} = ...` in the mutating controllers, `captcha`, OIDC, `forceLogin`) are untouched and still create sessions.

Behavior for a presented but expired or unknown cookie: Catalyst already deletes it and expires the cookie when it loads the expiry; the old code then immediately created a replacement session, and the new code does not.

Alternative considered: have the store refuse to persist a session that holds nothing but `__created`/`__updated`. That also covers future accidental reads, but the response would still carry a cookie and the id would still be handed out, so it fixes the table growth only.

### D6. Purge when a session is created

A session is created in one place in Perl (`create_session_id`). The store wraps it to run `delete from Sessions where expires < ?`, binding Perl's `time` rather than the database clock, since expiries are computed from Perl's clock and the database may be on another host. A timer or systemd unit would also work but adds a unit and module option for a table that stays small as long as creation is rare (D5).

Every other component that creates sessions must do the same; that is a spec requirement.

### D7. Lifetime semantics unchanged

`expires => 3600 * 24 * 7` stays in `Hydra.pm`, `expiry_threshold` stays at its default of 0, and sliding extension keeps writing on each request that loads a valid session. This preserves behavior and keeps the spec simple. Changing the threshold later would coarsen when expiry slides and would need a spec delta.

### D8. Cookie attributes come from plugin defaults

Verified in the plugin sources, not from a live response: name `hydra_session` (`appprefix . '_session'`), `Path=/` (`CGI::Simple::Cookie` default), `HttpOnly` and `SameSite=Lax` (`State::Cookie` defaults), `Expires` equal to the session expiry (no `cookie_expires`), and **no `Secure`** flag. Another component must reproduce these or sign-in will behave differently depending on which side issued the cookie.

## Risks / Trade-offs

- **Write per signed-in request** (D7) → single-row primary-key update, comparable to the two count queries `Root::begin` already runs per request. Not measured. Static-file requests that carry the cookie may add more; I did not confirm whether Catalyst persists an extension for them. Measure before tuning; if needed, raise `expiry_threshold` with a spec delta.
- **Private instances create a row per anonymous request** → with `private` set, `forceLogin` stores `referer`, so every anonymous request does a write. FastMmap absorbed this in a bounded cache; now rows live seven days. The purge keeps it bounded by a week of traffic, not unbounded. The private-mode gate is deferred; this is where it will want a fix.
- **Store error fails the request** → a missing table or a database error returns a server error rather than degrading to anonymous. Deliberate: failing open would sign users out silently.
- **Cross-process race at sign-in** → a client that receives `Set-Cookie` may immediately hit another component. The plugin's comment says it finalizes the session before the engine sends the response; I relied on that comment, so a test must log in and immediately look the row up from a second connection.
- **Encoding** → a flash message can contain a user name. The encoder must produce characters for DBD::Pg, not bytes, or non-ASCII text is double-encoded. `Model/DB.pm` sets no `pg_enable_utf8`, so test with a non-ASCII user name. jsonb also rejects `\u0000`; Hydra never writes one.
- **One-time sign-out** → accepted in the proposal.
- **Schema bookkeeping already fails at baseline** → `sql/schemas/verify.sh` reports `MISMATCH: v88` today, because `hydra.sql` changed (a comment, in `af687f4a`) after commit `18c6f062`, the commit recorded in `commit-88.txt`. The vendored `schemas/hydra-88.sql` must be taken from that commit's tree, not from the working copy, which also clears the mismatch.

## Migration Plan

1. Land `sql/hydra.sql`, `upgrade-89.sql`, the vendored `schemas/hydra-88.sql`, the `update-dbix.pl` moniker and the generated `Sessions` class together.
2. Land the store class, `Hydra.pm`, `CatalystUtils.pm`, `Root.pm` and `package.nix` changes. The server and `hydra-init` ship in the same package, so `hydra-init` runs the migration before the new server starts.
3. As a follow-up commit, add `schemas/commit-89.txt` pointing at the commit from step 1, as `dbc37cad` did for 88 (a file cannot contain the hash of the commit that adds it). Run `verify.sh`.
4. Deploy: `hydra-init` creates the table, `hydra-server` restarts, everyone signs in once.

Rollback: deploy the previous version. Hydra has no down migrations; the table stays and is unused. Sessions in the old `www/session_data` file that have not expired come back into force.

## Open Questions

- Should the NixOS module remove the stale `www/session_data` file after upgrade? It is harmless and can wait.
