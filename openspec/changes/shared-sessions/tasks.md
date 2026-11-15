# Tasks

Paths are relative to `subprojects/hydra/` unless they start with `subprojects/`, `packaging/` or `openspec/`. Tests live in `subprojects/hydra-tests/` and run with `meson test --test-args=<file> testsuite` (README "Testing").

Out of scope (design Open Questions): removing the stale `www/session_data` file after upgrade.

## 1. Schema: `Sessions` table (version 89)

- [ ] 1.1 Vendor `sql/schemas/hydra-88.sql` from the tree of the commit in `sql/schemas/commit-88.txt` (`git show <commit>:<path of hydra.sql in that tree>`, as resolved by `verify.sh`), not from the working copy; verify `sql/schemas/verify.sh` no longer reports `MISMATCH: v88`
- [ ] 1.2 Add the `Sessions` table and `IndexSessionsOnExpires` index to `sql/hydra.sql` exactly as in design D1, with a comment pointing at the session-storage spec for the row contract; verify `hydra-init` on an empty database creates both (`\d Sessions`)
- [ ] 1.3 Add `sql/migrations/upgrade-89.sql` creating the same table and index (`sql/meson.build` installs the whole `migrations/` directory, so no build change); verify `hydra-init` on a database at version 88 reaches 89 and `\d Sessions` matches 1.2
- [ ] 1.4 Add `"sessions" => "Sessions"` to the `moniker_map` in `sql/update-dbix.pl` and regenerate `lib/Hydra/Schema/Result/Sessions.pm`; verify `nix build .#checks.<system>.dbix-up-to-date` passes

## 2. Database-backed Catalyst store

- [ ] 2.1 Write the store class outside `Hydra::Plugin::` (e.g. `lib/Hydra/Session/Store/DB.pm`) implementing `get_session_data`, `store_session_data`, `delete_session_data` per design D3: `sha256_hex` of the id on every call, `insert ... on conflict (id) do update` through the DBIC storage handle, `expires` upserted as `greatest(Sessions.expires, excluded.expires)`, `flash:` no-op, unknown prefixes die; verify with a new `Hydra/Session/Store.t` covering each key prefix, the no-lowering rule, delete removing the row, unknown-prefix death, and that no row's `id` equals the raw session id
- [ ] 2.2 Encode `data` with a JSON encoder that dies on blessed references and hands DBD::Pg characters, not bytes (design D4); verify in the same test that storing a `URI` object dies and that a non-ASCII value (e.g. a user name `ålice`) round-trips unchanged through `get_session_data` and reads back correctly via `data->>'…'` in SQL
- [ ] 2.3 Purge in the store's `create_session_id` wrapper: `delete from Sessions where expires < ?` bound to Perl `time` (design D6); verify in the test that pre-inserted expired rows are gone after a session is created and unexpired rows remain
- [ ] 2.4 Verify `get_session_data` treats a row with null `data` as no session and a missing row as `expires` 0, covering the spec's "Expiry recorded before data" and "Unknown id" scenarios at the store level

## 3. Switch the web app to the new store

- [ ] 3.1 In `lib/Hydra.pm`, replace `Session::Store::FastMmap` with the new store and drop the `storage` key from `Plugin::Session`, keeping `expires => 3600 * 24 * 7` and the captcha `session_name`; keep `Cache::FastMmap` for `Plugin::Cache`; verify `hydra-server` starts and `GET /` succeeds against a migrated database
- [ ] 3.2 In `lib/Hydra/Helper/CatalystUtils.pm`, store `referer` as a string in `forceLogin` (`$c->request->uri->as_string`); verify with a test that an anonymous request to a sign-in-required page leaves `data->>'referer'` as a string URL and the post-login redirect still goes there
- [ ] 3.3 Remove `CatalystPluginSessionStoreFastMmap` from `subprojects/hydra/package.nix`, keeping `CacheFastMmap`; verify `nix build .#hydra` succeeds and `grep -r Session::Store::FastMmap subprojects/` finds nothing
- [ ] 3.4 Verify the existing `Hydra/Controller/User/*.t` (notably `local_auth.t`, `oidc.t`, `ldap.t`) and `Hydra/Helper/CatalystUtils.t` pass unchanged against the new store

## 4. No sessions for cookieless page views

- [ ] 4.1 Add a read-only flash helper to `lib/Hydra/Helper/CatalystUtils.pm` that reads `$c->flash` only when `$c->sessionid` is set and `$c->session_is_valid` (design D5), and use it for the flash reads in `Root::begin` (`flashMsg`, `successMsg`) and `Root::queue_GET` (`buildMsg`); leave all flash writers untouched; verified by 4.2
- [ ] 4.2 Add `Hydra/Controller/Root/sessions.t` covering the spec's "Anonymous page views do not create sessions" scenarios: no cookie on `/` and `/queue` sets no `hydra_session` cookie and adds no row; a well-formed unknown id on `/` adds no row; a flash message set by a writer is shown once and gone on the next request; starting an OIDC login without a cookie creates a row and sets the cookie

## 5. Cross-process contract tests

- [ ] 5.1 In `Hydra/Controller/Root/sessions.t`, sign in with a password and, from a second DBI connection opened before the response is read, look up `sha256_hex(cookie)` in `Sessions`; verify the row exists with `__user.username`, `__user_realm = 'dbic'`, integer `__created`/`__updated`, the cookie matches `^[0-9a-f]{40}$`, and `/current-user` describes the user (design risk "cross-process race")
- [ ] 5.2 Insert a row by hand in SQL as the spec's "Row written by a non-Perl component" scenario shows, then request `/current-user` with cookie `V`; verify the request is treated as `alice`, and that after it `expires` is at least `now + 604800`
- [ ] 5.3 Verify the invalid-session scenarios over HTTP: expired row, null `data`, and `data` without `__user` are each treated as not signed in on `/current-user`
- [ ] 5.4 Rewrite a session's `data` in SQL keeping `__flash`, then request a page; verify the flash is shown (spec "Unknown session keys are preserved")
- [ ] 5.5 Verify sign-out: `POST /logout` leaves the row without `__user`/`__user_realm` and the next page shows the sign-out flash; `GET /logout` with a valid token deletes the row and expires the `hydra_session` cookie
- [ ] 5.6 Verify the sign-in response's `Set-Cookie` has name `hydra_session`, `Path=/`, `HttpOnly`, `SameSite=Lax`, and `Expires` equal to the row's `expires` (design D8)
- [ ] 5.7 Verify that a request presenting a 40-hex cookie with no matching row (stand-in for a pre-upgrade FastMmap cookie) is anonymous and can sign in again

## 6. Documentation

- [ ] 6.1 Add a note to the "Upgrading" section of `subprojects/hydra-manual/src/installation.md` that this version moves sessions into the database, signs every user out once, and leaves `www/session_data` unused; verify `nix build .#hydra-manual` renders it
- [ ] 6.2 Add a short "Sessions" paragraph to `subprojects/hydra-manual/src/architecture.md` stating that web sessions live in the `Sessions` table and pointing other components at the session-storage spec for the row contract; verify `nix build .#hydra-manual` succeeds

## 7. Integration

- [ ] 7.1 Run the full `meson test -C build` suite and `meson test perlcritic`; verify both pass
- [ ] 7.2 Run `nix flake check` (covers `dbix-up-to-date` and the NixOS tests); verify it passes, including the `install` NixOS test, where `hydra-init.service` applies migration 89 before `hydra-server` serves `/`

## Workflow follow-up

- After the commit containing tasks 1.1–1.4 lands, add `sql/schemas/commit-89.txt` with that commit's hash in a follow-up commit (as `dbc37cad` did for 88) and run `sql/schemas/verify.sh`; this cannot be done in the same commit.
- Archive the change after review, syncing `specs/session-storage/spec.md` into `openspec/specs/`.
