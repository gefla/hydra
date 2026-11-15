# Spec Delta

## Purpose

Defines where Hydra web sessions are kept and the cross-process contract for the stored row, so that every Hydra web component sharing the database recognises the same signed-in users.

## ADDED Requirements

### Requirement: Sessions are stored in the database
Hydra SHALL persist web sessions in a `Sessions` table of the Hydra PostgreSQL database, with columns `id`, `data` and `expires`. It SHALL NOT keep session state in a process-local or file-based store.

#### Scenario: Sign-in is visible to another process
- **WHEN** a user signs in through the Perl web application
- **THEN** a row exists in `Sessions` whose `id` is the SHA-256 of that user's `hydra_session` cookie value (see "Session identifiers and row keys"), and any process with database access can read it

#### Scenario: No session file is written
- **WHEN** the Perl web application serves requests that create or change sessions
- **THEN** nothing is written to `www/session_data`

### Requirement: Session identifiers and row keys
A session's cookie value SHALL be 40 lowercase hexadecimal characters (160 bits) from a cryptographically secure source. The `Sessions.id` column SHALL hold the lowercase hexadecimal SHA-256 digest (64 characters) of the cookie value's 40 ASCII characters, never the cookie value itself, so that a copy of the table contains no usable cookies. Every component that reads or writes `Sessions` SHALL apply this derivation.

#### Scenario: Perl-created session
- **WHEN** the Perl web application creates a session
- **THEN** the cookie value matches `^[0-9a-f]{40}$` and the row's `id` equals the SHA-256 hex digest of that value

#### Scenario: Cookie value is not stored
- **WHEN** a session exists for a given cookie value
- **THEN** no row in `Sessions` has an `id` equal to that cookie value

#### Scenario: Cookie value written by another component
- **WHEN** a non-Perl component creates a session for the user to carry in the `hydra_session` cookie
- **THEN** the cookie value matches `^[0-9a-f]{40}$`, because the Perl web application rejects any other cookie value with a server error

### Requirement: Session data shape
The `data` column SHALL hold the session as a JSON object. A signed-in session SHALL contain `__user` (an object with a `username` member naming a Hydra user), `__user_realm` (the string `dbic`), and `__created` and `__updated` (integer epoch seconds).

#### Scenario: Row written by a non-Perl component is honoured
- **GIVEN** a row whose `id` is the SHA-256 hex digest of the cookie value `V`, whose `data` is `{"__user":{"username":"alice"},"__user_realm":"dbic","__created":1,"__updated":1}`, and whose `expires` is in the future
- **WHEN** a request to the Perl web application carries `V` in the `hydra_session` cookie
- **THEN** the request is treated as made by the user `alice`

#### Scenario: Values stay JSON-representable
- **WHEN** the Perl web application records the URL of a page that required sign-in
- **THEN** it is stored in `data` as a string under `referer`

### Requirement: Unknown session keys are preserved
A component that rewrites a session's `data` SHALL keep every key it does not itself manage, including `__flash`, `referer`, `oidc` and `oidc_provider`.

#### Scenario: Flash message survives a rewrite by another component
- **GIVEN** a session whose `data` holds a `__flash` message
- **WHEN** a non-Perl component rewrites that session's `data`
- **THEN** the `__flash` message is still present and is shown on the user's next Perl page

### Requirement: Sliding seven-day lifetime
A session SHALL remain valid until its `expires` (integer epoch seconds) has passed. Every request that presents a valid session SHALL move `expires` to at least seven days (604800 seconds) after that request. A session SHALL NOT have its `expires` shortened by a request.

#### Scenario: Active use extends the session
- **GIVEN** a session whose `expires` is one day away
- **WHEN** its owner makes a request to the Perl web application
- **THEN** `expires` becomes at least seven days after the request

#### Scenario: Idle session lapses
- **GIVEN** a session whose `expires` is in the past
- **WHEN** a request presents its cookie
- **THEN** the request is treated as not signed in

### Requirement: Invalid sessions are anonymous
A request SHALL be treated as not signed in when its cookie id has no row, the row's `data` is null, the session has expired, or `data` has no `__user`.

#### Scenario: Unknown id
- **WHEN** a request carries a well-formed id that has no row in `Sessions`
- **THEN** it is treated as not signed in, without error

#### Scenario: Expiry recorded before data
- **GIVEN** a row with an `expires` and a null `data`, as exists briefly while a new session is being created
- **WHEN** a request carries its id
- **THEN** it is treated as not signed in

#### Scenario: Session without a user
- **GIVEN** a session whose `data` has no `__user`, such as one holding only a redirect-back URL
- **WHEN** a request carries its id
- **THEN** the request is treated as not signed in

### Requirement: Sign-out ends the signed-in state
Signing out SHALL leave the session without a signed-in user: `__user` and `__user_realm` are no longer present, or the row is deleted. The CSRF-protected `GET /logout` SHALL delete the row and expire the `hydra_session` cookie. `POST /logout` SHALL keep the row, so the "no longer signed in" flash message is shown on the next page.

#### Scenario: POST sign-out
- **GIVEN** a signed-in user
- **WHEN** they `POST /logout`
- **THEN** the session's `data` has neither `__user` nor `__user_realm`, and presenting its id is treated as not signed in

#### Scenario: GET sign-out with a valid token
- **GIVEN** a signed-in user
- **WHEN** they request `GET /logout` with a valid token
- **THEN** no row remains for their id and the response expires the `hydra_session` cookie

### Requirement: Expired sessions are purged
Whenever a session is created, Hydra SHALL delete every `Sessions` row whose `expires` is in the past, so expired rows do not accumulate without operator action. This applies to every component that creates sessions.

#### Scenario: Purge on session creation
- **GIVEN** rows in `Sessions` whose `expires` is in the past
- **WHEN** a new session is created
- **THEN** those expired rows are deleted

### Requirement: Anonymous page views do not create sessions
A request that does not present a valid session SHALL NOT create a session, set a cookie, or write to `Sessions` merely to read a flash message. Flows that store state (sign-in, captcha, OIDC login, redirect back after a required sign-in) SHALL still create one.

#### Scenario: Cookieless page view
- **WHEN** a client with no cookie requests `/` or `/queue`
- **THEN** the response sets no `hydra_session` cookie and `Sessions` has no new row

#### Scenario: Cookie for an unknown session
- **WHEN** a client presents a well-formed id that has no row in `Sessions` and requests `/`
- **THEN** `Sessions` has no new row

#### Scenario: Flash message with a cookie
- **GIVEN** a session whose `data` holds a `__flash` message
- **WHEN** its cookie holder requests a page
- **THEN** the message is shown once and is gone on the following request

#### Scenario: Flow that needs state
- **WHEN** a cookieless client starts an OIDC login
- **THEN** a session is created and its cookie is set

### Requirement: Session cookie
The session cookie SHALL be named `hydra_session`, carry the session id as its value, have path `/`, be HttpOnly, use `SameSite=Lax`, and expire when the session expires.

#### Scenario: Cookie issued at sign-in
- **WHEN** a user signs in
- **THEN** the response sets `hydra_session` with the new session id, `Path=/`, `HttpOnly`, `SameSite=Lax`, and an expiry equal to the session's `expires`

### Requirement: Existing sign-in behavior is unchanged
Password sign-in, sign-out, flash messages, redirect back to the page that required sign-in, and OIDC login state SHALL behave as before this change.

#### Scenario: Password sign-in round trip
- **WHEN** a user signs in with a valid username and password and then requests `/current-user` with the returned cookie
- **THEN** the response describes that user

#### Scenario: OIDC login state survives the redirect
- **WHEN** a user starts an OIDC login and returns from the provider
- **THEN** the login completes using the state saved before the redirect

### Requirement: Existing sessions are not carried over
Sessions held in the previous file-based store SHALL NOT be migrated. After the upgrade, a request presenting such a cookie SHALL be treated as not signed in.

#### Scenario: Cookie from before the upgrade
- **WHEN** a user presents a `hydra_session` cookie issued before the upgrade
- **THEN** they are treated as not signed in and can sign in again
