# Database Schema (Logic) — Shop App Crawler

**Phiên bản:** 1.1 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt

DDL vật lý: `SQLITE_SCHEMA.sql` (SQLite), `PARQUET_SCHEMAS.md` (Parquet).
Từ điển field: `DATA_DICTIONARY.md`.

**v1.1 corrections:** (1) mọi `observed_at` là TIMESTAMP UTC (microsecond),
không còn DATE — phân biệt được nhiều lần quan sát trong ngày;
(2) tách `fetch_status` (truy cập) khỏi `review_status` (dữ liệu);
(3) bảng priority scheduling (design, chưa thuật toán);
(4) review identity nhiều tầng, không mặc định hash = ID ổn định;
(5) `current/` đảm bảo đúng 1 dòng/product_id về mặt vật lý.

Quy ước khóa (dùng nhất quán mọi nơi):
- `merchant_key TEXT` — token trong `/m/<token>` (vd `dogecore`). PK bảng merchants.
- `collection_key TEXT` — `<merchant_key>/<collection_id>` (vd `dogecore/166998114364`). PK bảng collections.
- `product_id INTEGER` — ID số trong `/products/<id>/<slug>` (13–14 chữ số, đã kiểm chứng). PK sản phẩm.

Quy ước thời gian: mọi cột thời gian quan sát là **TIMESTAMP UTC**.
Partition vật lý dùng cột DATE suy ra (`crawl_date`, `ym`) — xem `PARQUET_SCHEMAS.md`.

---

## 1. SQLite — vận hành (mutable)

### 1.1 merchants — 1,47M dòng

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| merchant_key | TEXT | **PK** | `/m/<token>` |
| slug | TEXT | NOT NULL | |
| display_name | TEXT | NULL | Vd "Salt.xo" |
| shop_url | TEXT | NOT NULL | |
| myshopify_domain | TEXT | NULL, UNIQUE | |
| apparel_prior | REAL | NOT NULL DEFAULT 0.5 | Prior POD-apparel |
| merchant_score | REAL | NOT NULL DEFAULT 0.5 | **Merchant Feedback**: cập nhật từ yield các collection đã crawl của merchant này |
| score_updated_at | TIMESTAMP | NULL | |
| first_seen / last_seen | TIMESTAMP | NOT NULL | v1.1: TIMESTAMP |
| source_surface, collector_version | TEXT | NOT NULL | |

Dedup: PK `merchant_key`; upsert (`last_seen` mới thắng).

### 1.2 collections — 524k dòng + priority scheduling (design)

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| collection_key | TEXT | **PK** | |
| merchant_key | TEXT | **FK** → merchants, NOT NULL, INDEX | |
| collection_id | INTEGER | NOT NULL | |
| slug / title | TEXT | NOT NULL / NULL | |
| intent_tier | TEXT | NULL | `garment`\|`pod_intent`\|`generic`\|`other` |
| product_count_est | INTEGER | NULL | |
| priority_score | REAL | NOT NULL DEFAULT 0.0 | **Collection Priority Score** (design; công thức là việc tương lai, versioned) |
| score_version | TEXT | NULL | Phiên bản công thức tính score |
| score_updated_at | TIMESTAMP | NULL | |
| crawl_count | INTEGER | NOT NULL DEFAULT 0 | |
| last_crawled_at | TIMESTAMP | NULL | |
| first_seen / last_seen | TIMESTAMP | NOT NULL | |
| source_surface, collector_version | TEXT | NOT NULL | |

Index `(priority_score DESC, last_crawled_at)` phục vụ scheduler.
Dedup: PK `collection_key`; UNIQUE(merchant_key, collection_id) dự phòng.

### 1.3 product_review_state — ≤54,5M dòng (v1.1: TÁCH fetch vs data)

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| product_id | INTEGER | **PK** | |
| review_count | INTEGER | NULL | **Last KNOWN** count; NULL = unknown |
| rating_avg | REAL | NULL | NULL đến khi product page mở được |
| review_status | TEXT | NOT NULL DEFAULT 'UNKNOWN', CHECK | **DATA state:** `UNKNOWN`\|`NO_REVIEWS`\|`HAS_REVIEWS` |
| fetch_status | TEXT | NOT NULL DEFAULT 'NOT_YET_FETCHED', CHECK | **ACCESS state:** `NOT_YET_FETCHED`\|`OK`\|`HTTP_403`\|`HTTP_404`\|`TIMEOUT`\|`CHALLENGE`\|`ERROR` |
| confidence | REAL | NOT NULL DEFAULT 1.0 | <1.0 cho suy luận (`NO_REVIEWS` conf 0.9) |
| last_success_at | TIMESTAMP | NULL | Lần quan sát data OK gần nhất |
| last_attempt_at | TIMESTAMP | NOT NULL | Lần thử fetch gần nhất (mọi kết quả) |
| source_surface | TEXT | NOT NULL | Surface của lần success gần nhất |
| collector_version, parser_version | TEXT | NOT NULL | |

**Bất biến quan trọng:** `fetch_status != 'OK'` **KHÔNG ĐƯỢC** thay đổi
`review_count`/`rating_avg`/`review_status` — chỉ cập nhật `fetch_status` và
`last_attempt_at`. HTTP 403 là sự kiện truy cập, không phải sự kiện dữ liệu.

Ngữ nghĩa data state:
- `UNKNOWN`: chưa từng quan sát review data (kể cả đã thử fetch nhưng fail).
- `NO_REVIEWS`: quan sát tile OK nhưng không hiện count → **suy luận** (conf 0.9).
- `HAS_REVIEWS`: quan sát được count (đã chuẩn hóa lúc parse).

### 1.4 crawl_jobs — nhỏ (không đổi, xem SQL)

### 1.5 collection_crawl_stats — yield mỗi collection (mới, v1.1)

Một dòng cho mỗi (collection, job) — đầu vào của Merchant Feedback và Priority Score.

| Cột | Kiểu | Ghi chú |
|---|---|---|
| stat_id | INTEGER **PK** | |
| collection_key | TEXT **FK** → collections, INDEX | |
| job_id | INTEGER **FK** → crawl_jobs | |
| crawled_at | TIMESTAMP NOT NULL | |
| tiles_observed | INTEGER NOT NULL | Số tiles thấy |
| products_found | INTEGER NOT NULL | SP unique trích được |
| new_products | INTEGER NOT NULL | Chưa từng thấy |
| unique_reviewed | INTEGER NOT NULL | SP mới unique có review |
| requests_used | INTEGER NOT NULL | Requests đã tốn |
| reward_r1/r10/r50/r100 | REAL NULL | unique reviewed (T) / requests × 1000 |

### 1.6 crawl_policy — knobs scheduling (mới, v1.1, design)

`(policy_key TEXT PK, policy_value TEXT, updated_at TIMESTAMP)`.
Keys dự kiến: `explore_budget_pct`, `score_version`, `reward_thresholds`,
`max_targets_per_job`, `collection_batch_size`. Giá trị cụ thể là việc tương lai.

### 1.7 crawl_targets — queue window ~1M + priority (v1.1)

Thêm `priority REAL NOT NULL DEFAULT 0.0` (từ Collection Priority Score) và index
`(status, priority DESC, next_retry_at)`. Dispatch: `ORDER BY priority DESC`
trong batch, đồng thời **dành `explore_budget_pct` mỗi batch cho target chưa từng
crawl / priority thấp** (exploration budget — chống starvation, design).
Lease/sweeper/backoff/DEAD(8 attempts)/prune DONE như cũ. Không lưu URL.

### 1.8 crawl_errors, 1.9 dq_violations, 1.10 sheets_export_log — không đổi (xem SQL)

---

## 2. Parquet — lịch sử bất biến + serving (v1.1)

Thay đổi chung: mọi `observed_at` → **TIMESTAMP**; partition giữ cột DATE suy ra
(`crawl_date`, `ym`).

### 2.1 lake/sitemap_urls — không đổi (xem PARQUET_SCHEMAS)

### 2.2 lake/products — snapshots: GIỮ MỌI QUAN SÁT (v1.1, sửa dedup)

Mỗi dòng = một quan sát. **Không dedup lúc ingest** — cùng `product_id` quan sát
3 lần/ngày thì lưu 3 dòng (TIMESTAMP phân biệt được). Dedup chỉ xảy ra lúc
compaction vào `current/`.

`(product_id BIGINT, url, title, price DOUBLE, currency, image_url, image_alt,
review_count BIGINT NULL, rating_avg DOUBLE NULL, observed_at TIMESTAMP,
crawl_date DATE [partition], source_surface, collector_version, parser_version)`

### 2.3 lake/product_collections, 2.4 product_merchants, 2.5 product_images

`observed_at` → TIMESTAMP (+ `crawl_date` partition). Còn lại không đổi.
`product_merchants.first/last_observed_at` → TIMESTAMP.

### 2.6 lake/reviews — identity nhiều tầng (v1.1, sửa #5)

Không mặc định hash nội dung là ID ổn định.

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| review_id | TEXT | no | **PK surrogate, luôn có**: `rv_<uuid4hex>` lúc ingest. Không suy ra từ nội dung |
| review_key_platform | TEXT | NULL | ID của platform nếu từng thấy (hiện chưa có) |
| product_id | BIGINT | no | |
| author / author_norm | TEXT | yes | `author_norm` = lowercase, strip — phục vụ match |
| created_at | TIMESTAMP | yes | NULL khi thiếu |
| content_sha256 | TEXT | yes | Hash nội dung — là **tín hiệu**, không phải ID |
| identity_method | TEXT | no | `platform_id` \| `author_time` \| `content_fallback` \| `surrogate_only` |
| identity_confidence | REAL | no | 1.0 → 0.3 theo method |
| version | INTEGER | no, DEFAULT 1 | Tăng khi phát hiện nội dung bị **sửa** (cùng identity, khác hash) |
| supersedes | TEXT | yes | `review_id` của version trước (NULL nếu v1) |
| rating/title/body | … | yes | Nội dung version này |
| verified_purchase/helpful_count/merchant_reply | … | yes | Như cũ |
| observed_at | TIMESTAMP | no | |
| source_surface | TEXT | no | |

Thứ tự ưu tiên identity: (1) `platform_id` nếu có; (2) `(product_id, author_norm,
created_at)` đủ 3 → `author_time`; (3) chỉ có nội dung → `content_fallback`
(conf thấp, gắn cờ `is_duplicate_candidate` khi có thể); (4) thiếu hết →
`surrogate_only` (lưu được, không dedup được — trung thực hơn là bịa ID).
Nội dung bị sửa: identity match + `content_sha256` đổi → dòng mới `version+1`,
`supersedes` trỏ dòng cũ; view current lấy `MAX(version)`.

### 2.7 lake/field_changes — observed_at TIMESTAMP, partition ym (không đổi khác)

**Quy tắc v1.1:** diff chạy trên **chuỗi quan sát liên tiếp** theo
`(product_id, observed_at TIMESTAMP)` — mọi thay đổi trong cùng ngày đều được ghi,
không gộp theo ngày.

### 2.8 current/ — ĐÚNG MỘT DÒNG/product_id (v1.1, sửa #6)

```
current/bucket-000.parquet … bucket-255.parquet   (KHÔNG partition ym)
```

- Mỗi bucket file chứa **đúng một dòng cho mỗi product_id** thuộc bucket đó —
  bất biến này do **writer đảm bảo**, không phải do query dedup.
- Compaction mỗi bucket: đọc bucket file cũ + deltas mới của bucket (predicate
  pushdown `product_id % 256 == b`) → dedup `ORDER BY observed_at DESC` → **ghi
  file mới, đổi tên nguyên tử**. Crash giữa chừng: file cũ còn nguyên.
- `current_manifest.json`: `{bucket, file, rows, max_observed_at, compacted_at}`
  cho mỗi bucket — phục vụ crash recovery của chính compaction và backup manifest.
- Query đọc `current/bucket-*.parquet` **không cần dedup lại** (DQ R15 kiểm tra).
- Lịch sử theo tháng không nằm ở `current/` — nằm ở `lake/` (bất biến).

---

## 3. Quan hệ & cardinality — không đổi (xem ENTITY_RELATIONSHIP.md),
thêm: `collections 1—n collection_crawl_stats`, `crawl_jobs 1—n collection_crawl_stats`.

## 4. Dedup tổng hợp (v1.1)

| Thực thể | Khóa dedup | Chiến lược |
|---|---|---|
| merchants/collections | PK tự nhiên | Upsert, mới thắng |
| products (lake) | **không dedup lúc ingest** | Giữ mọi quan sát (TIMESTAMP phân biệt); dedup chỉ ở compaction |
| products (current/) | `product_id` | Writer đảm bảo 1 dòng; atomic replace theo bucket |
| product_review_state | `product_id` | Upsert; fail fetch không đụng data columns |
| edges P–C / P–M | composite + timestamp | Append observations |
| images | `(product_id, image_url)` | Bỏ qua trùng |
| reviews (future) | identity nhiều tầng (§2.6) | Không mặc định hash = ID |
| conflicts | — | Ghi `field_changes`, mới nhất thắng ở current |

## 5. Sheets export spec — THIẾT KẾ, CHƯA TRIỂN KHAI

Curated mirror; 12 cột cố định
(`product_id, title, price, currency, review_count, rating_avg, merchant,
collection, url, image_url, first_seen, last_seen`); **500.000 dòng/file**
(≈6M cells < 10M); `valueInputOption=RAW`; đọc tên tab thật từ API
(mặc định `Trang tính1`); pre-size grid; freeze header; ghi `sheets_export_log`
với `source_manifest`. ~10 batch calls/shard.
