-- ============================================================================
-- SQLITE_SCHEMA.sql — Shop App Crawler
-- Version: 1.2 | Date: 2026-10-15 | Status: DRAFT (design only)
--
-- *** DESIGN DOCUMENT ONLY — DO NOT EXECUTE ***
-- This file is a DDL design blueprint. No database has been created from it.
-- It must pass review before any migration is run.
--
-- v1.2 corrections (2026-10-15 final design review):
--   1. New table ingest_batches: crash-safe ingest checkpoint (staging → parquet → sqlite).
--   2. crawl_policy seed defaults: explore_budget_pct=15 (APPROVED, configurable).
--   3. product_review_state: documented invariant — only successful observations update
--      review_count/rating_avg/review_status, INCLUDING real decreases.
--
-- Conventions:
--   * Natural keys from shop.app (merchant_key, collection_key, product_id).
--   * Row-level provenance on every table: source_surface, observed_at/last_seen,
--     collector_version, parser_version (parser_version only where parsing occurs).
--   * All timestamps UTC.
-- ============================================================================

PRAGMA journal_mode = WAL;

-- ----------------------------------------------------------------------------
-- 1. merchants — 1.47M rows (from storefronts sitemap)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS merchants (
    merchant_key      TEXT NOT NULL PRIMARY KEY,   -- token from /m/<token>
    slug              TEXT NOT NULL,
    display_name      TEXT,                          -- e.g. "Salt.xo"
    shop_url          TEXT NOT NULL,                 -- https://shop.app/m/<token>
    myshopify_domain  TEXT UNIQUE,                   -- xxx.myshopify.com, when extracted
    apparel_prior     REAL NOT NULL DEFAULT 0.5,     -- POD-apparel prior 0..1
    merchant_score    REAL NOT NULL DEFAULT 0.5,     -- feedback score from crawl yields
    score_updated_at  TIMESTAMP,                     -- last feedback update
    first_seen        TIMESTAMP NOT NULL,
    last_seen         TIMESTAMP NOT NULL,
    source_surface    TEXT NOT NULL,                 -- sitemap | merchant_tile | ...
    collector_version TEXT NOT NULL
);

-- ----------------------------------------------------------------------------
-- 2. collections — 524k rows (joins merchants via /m/<store> in URL)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collections (
    collection_key    TEXT NOT NULL PRIMARY KEY,   -- <merchant_key>/<collection_id>
    merchant_key      TEXT NOT NULL REFERENCES merchants(merchant_key),
    collection_id     INTEGER NOT NULL,
    slug              TEXT NOT NULL,                 -- e.g. graphic-tees
    title             TEXT,
    intent_tier       TEXT,                          -- garment|pod_intent|generic|other
    product_count_est INTEGER,
    -- priority scheduling (design only; scoring formula is future work)
    priority_score    REAL NOT NULL DEFAULT 0.0,     -- Collection Priority Score
    score_version     TEXT,                          -- scoring formula version
    score_updated_at  TIMESTAMP,
    crawl_count       INTEGER NOT NULL DEFAULT 0,
    last_crawled_at   TIMESTAMP,
    first_seen        TIMESTAMP NOT NULL,
    last_seen         TIMESTAMP NOT NULL,
    source_surface    TEXT NOT NULL,
    collector_version TEXT NOT NULL,
    UNIQUE (merchant_key, collection_id)
);
CREATE INDEX IF NOT EXISTS idx_collections_merchant ON collections(merchant_key);
CREATE INDEX IF NOT EXISTS idx_collections_priority
    ON collections(priority_score DESC, last_crawled_at);

-- ----------------------------------------------------------------------------
-- 3. product_review_state — up to 54.5M rows (mutable aggregate)
--    v1.1: fetch/access status SEPARATED from review data status.
--    v1.2 (APPROVED): ONLY a successful data observation updates review_count /
--    rating_avg / review_status — INCLUDING real decreases (a drop from 2700 to
--    2400 is recorded as-is and logged to field_changes; never clamped).
--    A failed fetch NEVER overwrites last known review data.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS product_review_state (
    product_id        INTEGER NOT NULL PRIMARY KEY,  -- numeric ID from /products/<id>/
    review_count      INTEGER,                       -- last KNOWN count; NULL = unknown
    rating_avg        REAL,                          -- NULL until product page accessible
    -- DATA state (what we know about reviews):
    review_status     TEXT NOT NULL DEFAULT 'UNKNOWN'
                        CHECK (review_status IN (
                          'UNKNOWN',      -- never observed with review data
                          'NO_REVIEWS',   -- observed tile without count (INFERENCE)
                          'HAS_REVIEWS'   -- observed count
                        )),
    -- ACCESS state (what happened on last fetch attempt):
    fetch_status      TEXT NOT NULL DEFAULT 'NOT_YET_FETCHED'
                        CHECK (fetch_status IN (
                          'NOT_YET_FETCHED',
                          'OK',
                          'HTTP_403', 'HTTP_404', 'TIMEOUT', 'CHALLENGE', 'ERROR'
                        )),
    confidence        REAL NOT NULL DEFAULT 1.0,     -- <1.0 for inferences
    last_success_at   TIMESTAMP,                     -- last OK data observation
    last_attempt_at   TIMESTAMP NOT NULL,            -- last fetch attempt (any outcome)
    source_surface    TEXT NOT NULL,
    collector_version TEXT NOT NULL,
    parser_version    TEXT NOT NULL
);
-- Invariant: fetch_status != 'OK' MUST NOT change review_count/rating_avg/review_status.
-- Only last_attempt_at and fetch_status are updated on failed fetches.

-- ----------------------------------------------------------------------------
-- 4. crawl_jobs — small
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crawl_jobs (
    job_id       INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    kind         TEXT NOT NULL
                   CHECK (kind IN ('sitemap_ingest','collection_crawl','merchant_crawl',
                                   'search_crawl','compaction','backup','sheets_export')),
    target_desc  TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'QUEUED'
                   CHECK (status IN ('QUEUED','RUNNING','PAUSED','DONE','FAILED')),
    created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at   TIMESTAMP,
    finished_at  TIMESTAMP,
    stats_json   TEXT                             -- {"fetched":62,"new_products":12,...}
);

-- ----------------------------------------------------------------------------
-- 5. collection_crawl_stats — per-collection yield (feeds Merchant Feedback)
--    One row per (collection, job). Basis for Collection Priority Score.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collection_crawl_stats (
    stat_id         INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    collection_key  TEXT NOT NULL REFERENCES collections(collection_key),
    job_id          INTEGER NOT NULL REFERENCES crawl_jobs(job_id),
    crawled_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    tiles_observed  INTEGER NOT NULL,              -- product tiles seen
    products_found  INTEGER NOT NULL,              -- unique products extracted
    new_products    INTEGER NOT NULL,              -- not seen before
    unique_reviewed INTEGER NOT NULL,              -- new unique products with reviews
    requests_used   INTEGER NOT NULL,              -- HTTP requests spent
    reward_r1       REAL,                          -- unique reviewed (T>=1) / requests * 1000
    reward_r10      REAL,                          -- T>=10 (primary KPI candidate)
    reward_r50      REAL,
    reward_r100     REAL
);
CREATE INDEX IF NOT EXISTS idx_ccs_collection
    ON collection_crawl_stats(collection_key, crawled_at DESC);

-- ----------------------------------------------------------------------------
-- 6. crawl_policy — scheduling knobs (design; values are future work)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crawl_policy (
    policy_key   TEXT NOT NULL PRIMARY KEY,       -- e.g. 'explore_budget_pct'
    policy_value TEXT NOT NULL,                   -- e.g. '15'
    updated_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- Intended keys: explore_budget_pct, score_version, reward_thresholds,
--                max_targets_per_job, collection_batch_size.
-- Seed defaults (APPROVED 2026-10-15; configurable, re-tune after benchmark):
--   INSERT INTO crawl_policy(policy_key, policy_value) VALUES
--     ('explore_budget_pct', '15'),
--     ('score_version', 'v0'),
--     ('reward_thresholds', '[1,10,50,100]'),
--     ('max_targets_per_job', '1000000');

-- ----------------------------------------------------------------------------
-- 7. ingest_batches — crash-safe ingest checkpoint (v1.2)
--    Protocol: staging JSONL (fsync) → Parquet (idempotent by file name) →
--    SQLite advance (transaction) → mark complete → clean staging.
--    Recovery replays from staging; Parquet batch files are never rewritten.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ingest_batches (
    batch_key    TEXT NOT NULL PRIMARY KEY,  -- <job_id>:<batch_seq>, e.g. 1042:000137
    job_id       INTEGER NOT NULL REFERENCES crawl_jobs(job_id),
    status       TEXT NOT NULL DEFAULT 'STAGED'
                  CHECK (status IN ('STAGED','PARQUET_DONE','COMPLETE')),
    parquet_path TEXT,                        -- lake path once written (deterministic name)
    rows_count   INTEGER,
    created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_ingest_batches_job
    ON ingest_batches(job_id, status);

-- ----------------------------------------------------------------------------
-- 8. crawl_targets — queue WINDOW (~1M rows, NOT 54.5M)
--    Crash-safe via leases: sweeper requeues expired IN_PROGRESS rows.
--    URLs are NOT stored here (resolved at dispatch via sitemap_urls join).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crawl_targets (
    target_key   TEXT NOT NULL PRIMARY KEY,  -- p:<product_id> | c:<collection_key> | m:<merchant_key>
    target_type  TEXT NOT NULL CHECK (target_type IN ('product','collection','merchant')),
    status       TEXT NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING','IN_PROGRESS','DONE','FAILED','DEAD')),
    priority     REAL NOT NULL DEFAULT 0.0,       -- from Collection Priority Score
    attempts     INTEGER NOT NULL DEFAULT 0,
    next_retry_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,  -- exponential backoff
    last_error   TEXT,
    job_id       INTEGER REFERENCES crawl_jobs(job_id),
    lease_until  TIMESTAMP                        -- NULL unless IN_PROGRESS
);
CREATE INDEX IF NOT EXISTS idx_targets_dispatch
    ON crawl_targets(status, priority DESC, next_retry_at);

-- Atomic claim pattern (for the future worker):
-- UPDATE crawl_targets SET status='IN_PROGRESS', lease_until = datetime('now','+10 minutes')
--  WHERE target_key IN (SELECT target_key FROM crawl_targets
--   WHERE status='PENDING' AND next_retry_at <= CURRENT_TIMESTAMP
--   ORDER BY priority DESC LIMIT 1000);
-- Sweeper pattern (on startup + periodic):
-- UPDATE crawl_targets SET status='IN_PROGRESS'→'PENDING', attempts=attempts+1, lease_until=NULL
--  WHERE status='IN_PROGRESS' AND lease_until < CURRENT_TIMESTAMP;
-- Exploration: scheduler reserves explore_budget_pct of each batch for
-- low-priority/never-crawled targets (anti-starvation).

-- ----------------------------------------------------------------------------
-- 9. crawl_errors — sampled, append-only
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crawl_errors (
    error_id    INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    target_key  TEXT NOT NULL,
    job_id      INTEGER REFERENCES crawl_jobs(job_id),
    http_status INTEGER,                            -- NULL for timeouts
    error_class TEXT NOT NULL
                   CHECK (error_class IN ('cloudflare','http_403','http_404',
                                          'timeout','parse','network')),
    observed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    detail      TEXT                                -- sampled, max 100/job/class
);
CREATE INDEX IF NOT EXISTS idx_errors_target ON crawl_errors(target_key);
CREATE INDEX IF NOT EXISTS idx_errors_class ON crawl_errors(error_class, observed_at);

-- ----------------------------------------------------------------------------
-- 10. dq_violations — sampled
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dq_violations (
    violation_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    rule_id      TEXT NOT NULL,                     -- see DATA_QUALITY_RULES.md
    entity_type  TEXT NOT NULL,
    entity_key   TEXT NOT NULL,
    detail       TEXT,
    observed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_dq_rule ON dq_violations(rule_id, observed_at);

-- ----------------------------------------------------------------------------
-- 11. sheets_export_log — tiny
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sheets_export_log (
    export_id       INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    subset_name     TEXT NOT NULL,                  -- e.g. top_reviewed_hoodies
    spreadsheet_id  TEXT NOT NULL,
    sheet_count     INTEGER NOT NULL,
    rows_total      INTEGER NOT NULL,
    exported_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    source_manifest TEXT NOT NULL,                  -- which backup manifest it came from
    status          TEXT NOT NULL DEFAULT 'DONE'
);
