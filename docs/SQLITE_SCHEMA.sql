-- ============================================================================
-- SQLITE_SCHEMA.sql — Shop App Crawler
-- Version: 1.0 | Date: 2026-10-15 | Status: DRAFT (design only)
--
-- *** DESIGN DOCUMENT ONLY — DO NOT EXECUTE ***
-- This file is a DDL design blueprint. No database has been created from it.
-- It must pass review before any migration is run.
--
-- Conventions:
--   * Natural keys from shop.app (merchant_key, collection_key, product_id).
--   * Row-level provenance on every table: source_surface, observed_at,
--     collector_version, parser_version (parser_version only where parsing occurs).
--   * review_status enum: NOT_YET_FETCHED | NO_REVIEWS | HAS_REVIEWS |
--                         INACCESSIBLE | MISSING  (see DATABASE_SCHEMA.md)
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
    first_seen        DATE NOT NULL,
    last_seen         DATE NOT NULL,
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
    first_seen        DATE NOT NULL,
    last_seen         DATE NOT NULL,
    source_surface    TEXT NOT NULL,
    collector_version TEXT NOT NULL,
    UNIQUE (merchant_key, collection_id)
);
CREATE INDEX IF NOT EXISTS idx_collections_merchant ON collections(merchant_key);

-- ----------------------------------------------------------------------------
-- 3. product_review_state — up to 54.5M rows (mutable aggregate)
--    The HOT table: one upsert per tile observation.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS product_review_state (
    product_id        INTEGER NOT NULL PRIMARY KEY,  -- numeric ID from /products/<id>/
    review_count      INTEGER,                       -- NULL = unknown; see review_status
    rating_avg        REAL,                          -- NULL until product page accessible
    review_status     TEXT NOT NULL
                        CHECK (review_status IN (
                          'NOT_YET_FETCHED','NO_REVIEWS','HAS_REVIEWS',
                          'INACCESSIBLE','MISSING')),
    confidence        REAL NOT NULL DEFAULT 1.0,     -- <1.0 for inferences
    observed_at       DATE NOT NULL,                 -- most recent observation
    source_surface    TEXT NOT NULL,
    collector_version TEXT NOT NULL,
    parser_version    TEXT NOT NULL
);

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
-- 5. crawl_targets — queue WINDOW (~1M rows, NOT 54.5M)
--    Crash-safe via leases: sweeper requeues expired IN_PROGRESS rows.
--    URLs are NOT stored here (resolved at dispatch via sitemap_urls join).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crawl_targets (
    target_key   TEXT NOT NULL PRIMARY KEY,  -- p:<product_id> | c:<collection_key> | m:<merchant_key>
    target_type  TEXT NOT NULL CHECK (target_type IN ('product','collection','merchant')),
    status       TEXT NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING','IN_PROGRESS','DONE','FAILED','DEAD')),
    attempts     INTEGER NOT NULL DEFAULT 0,
    next_retry_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,  -- exponential backoff
    last_error   TEXT,
    job_id       INTEGER REFERENCES crawl_jobs(job_id),
    lease_until  TIMESTAMP                        -- NULL unless IN_PROGRESS
);
CREATE INDEX IF NOT EXISTS idx_targets_dispatch
    ON crawl_targets(status, next_retry_at);

-- Atomic claim pattern (for the future worker):
-- UPDATE crawl_targets SET status='IN_PROGRESS', lease_until = datetime('now','+10 minutes')
--  WHERE target_key IN (SELECT target_key FROM crawl_targets
--   WHERE status='PENDING' AND next_retry_at <= CURRENT_TIMESTAMP LIMIT 1000);
-- Sweeper pattern (on startup + periodic):
-- UPDATE crawl_targets SET status='PENDING', attempts=attempts+1, lease_until=NULL
--  WHERE status='IN_PROGRESS' AND lease_until < CURRENT_TIMESTAMP;

-- ----------------------------------------------------------------------------
-- 6. crawl_errors — sampled, append-only
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
-- 7. dq_violations — sampled
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
-- 8. sheets_export_log — tiny
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
