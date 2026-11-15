-- Web sessions, shared with every other Hydra web component.
--
-- See the session-storage spec (openspec/specs/session-storage/spec.md) for
-- the row contract, and sql/hydra.sql for the same table in fresh installs.
create table Sessions (
    id       text   primary key not null,        -- hex SHA-256 of the cookie value
    data     jsonb,                              -- Catalyst session hash; null until written
    expires  bigint not null default 0           -- epoch seconds; 0 = not yet recorded
);
create index IndexSessionsOnExpires on Sessions(expires);
