-- Creates the `pii` database for pii_vault isolation.
--
-- Idempotent: rerunning with the database already existing does NOT fail
-- (does not abort postgres startup). The DO $$ ... EXCEPTION ... END $$
-- block catches duplicate_database (SQLSTATE 42P04) and continues. This
-- matters when an operator wipes the data volume (docker compose down -v)
-- and recreates it — the init script reruns and would otherwise abort
-- startup with "ERROR: database pii already exists".
--
-- Init scripts in /docker-entrypoint-initdb.d/ run only on the first
-- startup (when the data dir is empty); subsequent restarts ignore them.
-- Schema migrations live in /migrations/ and are
-- applied manually via psql in the documented order — this script is for
-- cluster-level provisioning only (databases, roles, extensions).
--
-- If roles with differentiated permissions for `brain` vs `pii` are needed
-- later, add a separate init script.

DO $$
BEGIN
    CREATE DATABASE pii;
EXCEPTION WHEN duplicate_database THEN
    RAISE NOTICE 'database pii already exists, skipping CREATE';
END
$$;
