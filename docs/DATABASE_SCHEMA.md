# Database Schema (Logic) — Shop App Crawler

**Phiên bản:** 1.2 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt (vòng cuối)

DDL vật lý: `SQLITE_SCHEMA.sql` (SQLite), `PARQUET_SCHEMAS.md` (Parquet).
Từ điển field: `DATA_DICTIONARY.md`.

**v1.2 corrections (final review):**
(1) `observation_id` ổn định + thứ tự xác định `(observed_at, observation_id)`;
idempotent replay theo batch; (2) DQ R14 viết lại — hết mâu thuẫn với `NO_REVIEWS`;
(3) `current/` publication nguyên tử qua **generation manifest**;
(4) recovery protocol SQLite↔Parquet (staging → parquet → sqlite);
(5) `explore_budget_pct` mặc định **15%** (APPROVED, cấu hình được);
(6) review count **giảm thật được ghi nhận** (không clamp).

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

**Bất biến quan trọng (APPROVED):** `fetch_status != 'OK'` **KHÔNG ĐƯỢC** thay đổi
`review_count`/`rating_avg`/`review_status` — chỉ cập nhật `fetch_status` và
`last_attempt_at`. HTTP 403 là sự kiện truy cập, không phải sự kiện dữ liệu.

**Quy tắc upsert (APPROVED):** chỉ một lần quan sát dữ liệu **thành công** mới được
cập nhật 3 trường trên — **kể cả khi giá trị giảm thật** (vd count 2700→2400 được
ghi nhận nguyên vẹn, đồng thời ghi `field_changes`; không clamp, không coi là nhiễu).
Upsert có tính idempotent: chỉ áp dụng khi `observed_at` mới hơn `last_success_at`.

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
Seed defaults (**APPROVED** 2026-10-15, cấu hình được, hiệu chỉnh sau benchmark):

| policy_key | policy_value | Ghi chú |
|---|---|---|
| `explore_budget_pct` | `15` | % mỗi batch dành cho target chưa/low-priority (chống starvation) |
| `score_version` | `v0` | Version công thức Collection Priority Score |
| `reward_thresholds` | `[1,10,50,100]` | Vector R_T |
| `max_targets_per_job` | `1000000` | Trần queue window |

### 1.7 ingest_batches — checkpoint ingest chống crash (mới, v1.2)

`(batch_key TEXT PK` = `<job_id>:<batch_seq>`, `job_id FK`, `status` ∈
`STAGED|PARQUET_DONE|COMPLETE`, `parquet_path`, `rows_count`, `created_at`,
`completed_at)`. Xem quy trình recovery ở mục 6.

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
3 lần/ngày thì lưu 3 dòng.

**Định danh quan sát (v1.2):** không dùng `(product_id, observed_at)` làm key —
TIMESTAMP có thể trùng (clock skew, batch cùng microsecond).

| Cột | Kiểu | Ghi chú |
|---|---|---|
| observation_id | TEXT NOT NULL | **Định danh ổn định**: `<job_id>:<batch_seq>:<row_seq>` (vd `1042:000137:000012`). Gán 1 lần lúc ingest, không bao giờ tính lại |
| product_id | BIGINT NOT NULL | |
| observed_at | TIMESTAMP NOT NULL | Gán lúc **fetch** (crawler), ingest giữ nguyên → replay an toàn |

**Thứ tự xác định:** `ORDER BY observed_at, observation_id` — total order vì
`observation_id` unique. Mọi consumer (compaction, diff, export) dùng thứ tự này.

**Idempotent replay:** file Parquet đặt tên xác định `part-<job_id>-<batch>.parquet`.
Replay batch đã xong → file đã tồn tại → **skip**, không tạo observations trùng.
`ingest_batches` ghi nhận trạng thái từng batch.

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

### 2.8 current/ — ĐÚNG MỘT DÒNG/product_id + PUBLICATION NGUYÊN TỬ (v1.2)

```
current/
  generations/
    gen_0001/bucket-000.parquet … bucket-255.parquet   # chỉ bucket được rewrite
    gen_0002/...
  manifests/
    manifest_gen_0001.json …    # đủ 256 buckets/generation (file có thể trỏ về gen cũ)
  current_latest.json           # {"generation": "gen_0007"} — con trỏ nguyên tử
```

- Mỗi generation là **snapshot nhất quán**: manifest liệt kê đủ 256 buckets;
  bucket không đổi trỏ về file của generation trước (không copy).
- Publication = **atomic rename** `current_latest.json`. Crash giữa lúc ghi bucket →
  con trỏ chưa đổi → reader vẫn thấy generation cũ nhất quán. **Không bao giờ lộ
  snapshot lẫn lộn nhiều generation.**
- Staging ghi vào `generations/<gen>/` trước; dọn staging mồ côi (>24h, không được
  manifest nào trỏ) bằng job dọn dẹp.
- `current_manifest.json` cũ thay bằng `manifests/manifest_<gen>.json` +
  `current_latest.json`. Chi tiết: `PARTITION_AND_COMPACTION.md`.

---

## 3. Quan hệ & cardinality — không đổi (xem ENTITY_RELATIONSHIP.md),
thêm: `collections 1—n collection_crawl_stats`, `crawl_jobs 1—n collection_crawl_stats`.

## 4. Dedup tổng hợp (v1.2)

| Thực thể | Khóa dedup | Chiến lược |
|---|---|---|
| merchants/collections | PK tự nhiên | Upsert, mới thắng |
| products (lake) | `observation_id` (`<job_id>:<batch>:<row>`) | **Không dedup** — mỗi quan sát 1 dòng; replay idempotent theo tên file batch |
| products (current/) | `product_id` trong 1 generation | Writer đảm bảo 1 dòng; publication nguyên tử qua generation manifest |
| product_review_state | `product_id` | Upsert idempotent: chỉ áp dụng khi `observed_at` mới hơn `last_success_at`; giảm thật được ghi nhận |
| edges P–C / P–M | composite + timestamp | Append observations |
| images | `(product_id, image_url)` | Bỏ qua trùng |
| reviews (future) | identity nhiều tầng (§2.6) | Không mặc định hash = ID |
| conflicts | — | Ghi `field_changes`, mới nhất thắng ở current |

## 6. Crash recovery: SQLite ↔ Parquet (v1.2)

Thứ tự ghi chuẩn cho mỗi batch (bắt buộc):

```
1. STAGE:   crawler ghi observations thô → ingest_staging/<job_id>/batch-<n>.jsonl + fsync
            → INSERT ingest_batches(batch_key, status='STAGED')
2. PARQUET: convert staging → lake/.../part-<job_id>-<batch>.parquet
            (file đã tồn tại → SKIP — idempotent)
            → UPDATE ingest_batches SET status='PARQUET_DONE'
3. SQLITE:  transaction: upsert product_review_state (idempotent theo observed_at),
            targets → DONE, checkpoint job
            → UPDATE ingest_batches SET status='COMPLETE'
4. CLEAN:   xóa staging file
```

Phân tích 2 chiều crash:

| Crash tại | Hậu quả | Phục hồi (lúc khởi động) |
|---|---|---|
| Sau (1), trước (2) | Staging có, Parquet chưa | Replay từ staging → (2)(3)(4). Không mất data |
| Sau (2), trước (3) | **Parquet có, SQLite chưa** | Quét batch `PARQUET_DONE` chưa `COMPLETE` → chạy lại (3) từ chính file Parquet (upsert idempotent). Không duplicate observations vì Parquet không ghi lại |
| Sau (3), trước (4) | SQLite xong, staging còn | Batch đã `COMPLETE` → chỉ xóa staging thừa |
| Giữa (3) | Transaction SQLite | WAL atomicity: commit hoặc không — không có trạng thái nửa vời |

Nguyên tắc vàng: **lake là source of truth có thể replay; SQLite suy ra được từ lake,
không bao giờ ngược lại.** Mọi bước đều idempotent nên replay không tạo duplicate
ngoài ý muốn.

Trường hợp "SQLite checkpoint đã cập nhật nhưng Parquet chưa commit" **không thể xảy ra**
trong luồng chuẩn (SQLite luôn sau Parquet). Nếu xảy ra do can thiệp thủ công, quy trình
phục hồi: staging còn → ghi Parquet → xong; staging mất → đánh dấu batch `FAILED`,
cho crawl lại (observations mới, không ghi đè).

## 5. Sheets export spec — THIẾT KẾ, CHƯA TRIỂN KHAI

Curated mirror; 12 cột cố định
(`product_id, title, price, currency, review_count, rating_avg, merchant,
collection, url, image_url, first_seen, last_seen`); **500.000 dòng/file**
(≈6M cells < 10M); `valueInputOption=RAW`; đọc tên tab thật từ API
(mặc định `Trang tính1`); pre-size grid; freeze header; ghi `sheets_export_log`
với `source_manifest`. ~10 batch calls/shard.
