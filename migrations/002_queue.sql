-- Async task queue. The supervisor worker polls this table with
-- SELECT ... FOR UPDATE SKIP LOCKED. SERIAL is used (not UUID) because
-- queue rows are short-lived and integer IDs are fine for internal
-- bookkeeping; ordering is the job of (priority, execute_at), not the PK.

CREATE TABLE IF NOT EXISTS queue (
    id            SERIAL PRIMARY KEY,
    task_type     VARCHAR(64) NOT NULL,
    payload       JSONB NOT NULL,
    origin        VARCHAR(32) NOT NULL CHECK (
        origin IN ('proxy', 'mcp_client', 'webhook', 'cron')
    ),
    target_agent  VARCHAR(32) DEFAULT 'internal',
    status        VARCHAR(16) NOT NULL DEFAULT 'pending' CHECK (
        status IN ('pending', 'processing', 'done', 'failed', 'paused')
    ),
    priority      INT DEFAULT 0,
    -- execute_at is NOT NULL: tasks without a schedule use NOW() via DEFAULT.
    -- (Spec rule states "execute_at is TIMESTAMPTZ (not NULL)" but the
    -- DDL was missing the NOT NULL — applied here.)
    execute_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    locked_at     TIMESTAMPTZ,
    locked_by     VARCHAR(32),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    retry_count   INT DEFAULT 0,
    error_message TEXT,
    -- payload_hash pinned to hex 16 chars 
    -- Producer: hashlib.sha256(payload).hexdigest()[:16]
    -- Pinning avoids silent encoding
    -- mismatches between clients — bad data fails the CHECK instead of
    -- silently becoming a different hash namespace.
    payload_hash  VARCHAR(16) NOT NULL
        CHECK (payload_hash ~ '^[0-9a-f]{16}$')
);

-- UNIQUE partial index for idempotency
-- Partial on status IN ('pending', 'processing') — rows that reach
-- 'done'/'failed' drop out of the index, so re-enqueues with the same
-- hash are still allowed after the previous task is fully resolved.
CREATE UNIQUE INDEX IF NOT EXISTS idx_queue_hash ON queue(payload_hash)
    WHERE status IN ('pending', 'processing');

-- Partial index that drives the supervisor poll. ORDER BY priority DESC,
-- execute_at ASC matches the polling query so PG can use an index-only
-- scan on the candidate set. The predicate pins the index to the only
-- rows the worker actually competes for.
CREATE INDEX IF NOT EXISTS idx_queue_poll ON queue(priority DESC, execute_at ASC)
    WHERE status = 'pending' AND target_agent = 'internal';

-- Recovery index for zombie tasks (rows stuck in 'processing' because
-- a worker died mid-task). The supervisor periodically scans this to
-- reset old tasks back to 'pending'.
CREATE INDEX IF NOT EXISTS idx_queue_zombie ON queue(created_at)
    WHERE status = 'processing';

-- ── Trigger: auto-bump updated_at on UPDATE ──
-- DEFAULT NOW() only covers INSERT. Without a trigger, UPDATEs leave
-- updated_at stale, and any query that depends on it (e.g. 017
-- active_summary with `WHERE updated_at > NOW() - INTERVAL '14 days'`)
-- becomes a fake filter. The trigger guards this permanently.
--
-- `CREATE OR REPLACE` makes
-- the duplication idempotent: whichever migration runs second is a
-- no-op. App code that explicitly sets updated_at = NOW() is fine —
-- the trigger overwrites with a slightly later timestamp, but the
-- value is still NOW() and the effect is idempotent.
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- CREATE TRIGGER has no IF NOT EXISTS in PG. Wrap in a DO block that
-- checks pg_trigger; this makes the migration safely re-runnable.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'set_queue_updated_at'
          AND tgrelid = 'queue'::regclass
    ) THEN
        CREATE TRIGGER set_queue_updated_at
            BEFORE UPDATE ON queue
            FOR EACH ROW
            EXECUTE FUNCTION trigger_set_updated_at();
    END IF;
END
$$;
