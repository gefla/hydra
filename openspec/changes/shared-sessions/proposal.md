# Proposal

## Why

Hydra's web sessions live in a Catalyst `Session::Store::FastMmap` file under `www/session_data`. That file is private to the Perl process: nothing else can read or write it. The planned Haskell web/API component (strangler behind nginx, existing URL paths kept) must recognise users who signed in through Perl, and Perl must recognise users who signed in through Haskell. A store both sides can reach is a prerequisite, so it ships first, on its own, where a failure can only be a Perl-side failure.

## What Changes

- Add a `Sessions` table to PostgreSQL (`sql/hydra.sql`, plus `sql/migrations/upgrade-89.sql` and the schema-snapshot bookkeeping the migration check requires).
- Add a Catalyst session store class backed by that table, and use it in `Hydra.pm` in place of `Session::Store::FastMmap`.
- Stringify the one non-JSON-safe session value: `referer` is stored as a `URI` object today (`Helper/CatalystUtils.pm`).
- Stop creating a session for cookieless page views. Today `Root::begin` reads `$c->flash` on every request, which allocates a session id and writes to the store even for anonymous clients. With a database-backed store that would be one new row per bot or health-check request, kept for seven days. Flows that need state (sign-in, captcha, OIDC, redirect back after a required sign-in) still create sessions.
- Purge expired rows whenever a session is created, because nothing evicts them any more.
- Drop `CatalystPluginSessionStoreFastMmap` from `package.nix`. `CacheFastMmap` stays: `Plugin::Cache` still uses it for OIDC discovery.
- Define, as a spec, the session row format that a non-Perl reader/writer must follow (id format, data shape, expiry, what "no session" means).
- **BREAKING**: sessions held in the FastMmap file are not migrated. Every signed-in user is signed out once, at upgrade. Downgrade is safe: the table is additive and is simply unused.

No Haskell code, nginx, or login flow is part of this change.

## Capabilities

### New Capabilities

- `session-storage`: where Hydra web sessions live and the cross-process contract for the row format, lifetime, and lookup semantics, so any Hydra web component can read and write the same sessions.

### Modified Capabilities

(none; `openspec/specs/` is empty)

## Impact

- **Database:** new `Sessions` table, schema version 88 to 89. Applied by `hydra-init`, which `hydra-server` already requires (`nixos-modules/web-app.nix`). The generated `Hydra::Schema::Result::Sessions` class must be added; the `dbix-up-to-date` flake check enforces this.
- **Perl:** `lib/Hydra.pm` (plugin list, `Plugin::Session` config), new store class, `lib/Hydra/Helper/CatalystUtils.pm` (`referer`), `lib/Hydra/Controller/Root.pm` (`begin` and `queue_GET` flash reads).
- **Packaging:** `subprojects/hydra/package.nix` (Perl dependency list).
- **Operations:** one-time sign-out at upgrade. The `www/session_data` file becomes unused. Expired rows are purged by the code that creates sessions; no new timer or unit.
- **Unaffected:** `Plugin::Cache` (OIDC discovery cache), the evaluator, queue-runner, builder, `hydra-ws`, and the Rust crates.
