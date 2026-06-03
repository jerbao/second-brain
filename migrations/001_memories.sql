-- pgvector extension (the pgvector/pgvector:pg18-trixie image ships it,
-- so this is a no-op when the image already has it; idempotent guard
-- keeps the migration runnable on bare PG 18 installs too).
CREATE EXTENSION IF NOT EXISTS vector;

-- PostgreSQL 18 provides a native uuidv7() function, so we do NOT need
-- the uuid-ossp extension here. v7 yields time-ordered UUIDs (sortable
-- by creation time, good for keyset pagination and B-tree locality).
-- (Decision 2026-06-03: prefer PG-native v7 over the external pg_uuidv7
-- extension to avoid an extra dependency.)

-- ENUM type for evidence_kind
CREATE TYPE evidence_kind AS ENUM ('direct', 'inferred', 'manual', 'system');

-- Main table: memories
CREATE TABLE memories (
    id              UUID PRIMARY KEY DEFAULT uuidv7(),
    content         TEXT NOT NULL,
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    type            VARCHAR(32) NOT NULL CHECK (
        type IN (
            'identity', 'preference', 'goal', 'project', 'habit',
            'decision', 'constraint', 'relationship', 'episode',
            'reflection', 'knowledge', 'task'
        )
    ),
    embedding       VECTOR(1536) NOT NULL,  -- dimension fixed to match EMBEDDING_DIMENSIONS=1536
    namespace       VARCHAR(64) NOT NULL DEFAULT 'personal',
    tier            VARCHAR(10) DEFAULT 'HOT' CHECK (tier IN ('HOT', 'WARM', 'COLD')),
    confidence      FLOAT NOT NULL DEFAULT 0.7,
    importance      FLOAT NOT NULL DEFAULT 0.5,
    durability      FLOAT NOT NULL DEFAULT 0.5,
    evidence_count  INT DEFAULT 1,
    evidence_kind   evidence_kind NOT NULL DEFAULT 'direct',
    dismissed       BOOLEAN NOT NULL DEFAULT false,
    superseded_by   UUID REFERENCES memories(id),
    last_accessed   TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- IVFFlat index for vector similarity search (partial: dismissed = false).
-- Index name keeps "namespace" for forward compatibility, but the current
-- predicate is namespace-agnostic. If per-namespace isolation is needed
-- later, add a per-namespace partial index or include namespace as a
-- leading column on the index. lists=100 is a sensible default for the
-- expected row scale; revisit if the table grows past ~1M rows.
CREATE INDEX idx_memories_namespace_embedding ON memories
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100)
    WHERE dismissed = false;

-- GIN index for multilingual full-text / BM25 search. The 'simple'
-- tokenizer is language-agnostic and supports Portuguese/English/etc.
-- without per-language configuration.
CREATE INDEX idx_memories_content_gin ON memories
    USING GIN (to_tsvector('simple', content));
