# Database Schema (Logic) — Shop App Crawler

**Phiên bản:** 1.0 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt

DDL vật lý: `SQLITE_SCHEMA.sql` (SQLite), `PARQUET_SCHEMAS.md` (Parquet).
Từ điển field: `DATA_DICTIONARY.md`.

Quy ước khóa (dùng nhất quán mọi nơi):
- `merchant_key TEXT` — token trong `/m/<token>` (vd `dogecore`, `saltxo`). PK bảng merchants.
- `collection_key TEXT` — `<merchant_key>/<collection_id>` (vd `dogecore/166998114364`). PK bảng collections.
- `product_id INTEGER` — ID số trong `/products/<id>/<slug>` (13–14 chữ số, đã kiểm chứng). PK sản phẩm.

---

## 1. SQLite — vận hành (mutable)

### 1.1 merchants — 1,47M dòng (giả định: từ sitemap storefronts)

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| merchant_key | TEXT | **PK** | `/m/<token>`, join trực tiếp với collections |
| slug | TEXT | NOT NULL | slug hiển thị (thường = token) |
| display_name | TEXT | NULL | Tên shop (vd "Salt.xo") — có khi crawl merchant page |
| shop_url | TEXT | NOT NULL | `https://shop.app/m/<token>` |
| myshopify_domain | TEXT | NULL, UNIQUE | `xxx.myshopify.com` nếu trích được |
| apparel_prior | REAL | NOT NULL DEFAULT 0.5 | Prior POD-apparel 0..1 (khởi tạo từ collection scoring) |
| first_seen / last_seen | DATE | NOT NULL | |
| source_surface, collector_version | TEXT | NOT NULL | Provenance row-level |

Dedup: PK `merchant_key`. Upsert khi gặp lại (`last_seen`, `display_name` cập nhật).

### 1.2 collections — 524k dòng (đã kiểm chứng join `/m/<store>`)

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| collection_key | TEXT | **PK** | `<merchant_key>/<collection_id>` |
| merchant_key | TEXT | **FK** → merchants, NOT NULL, INDEX | |
| collection_id | INTEGER | NOT NULL | ID số trong URL |
| slug | TEXT | NOT NULL | slug collection (vd `graphic-tees`) |
| title | TEXT | NULL | Tiêu đề hiển thị |
| intent_tier | TEXT | NULL | `garment` \| `pod_intent` \| `generic` \| `other` (phục vụ priority scoring) |
| product_count_est | INTEGER | NULL | Ước lượng từ lần crawl gần nhất |
| first_seen / last_seen | DATE | NOT NULL | |
| source_surface, collector_version | TEXT | NOT NULL | |

Dedup: PK `collection_key`. UNIQUE(merchant_key, collection_id) dự phòng.

### 1.3 product_review_state — ≤54,5M dòng (aggregate hiện tại, mutable)

Bảng "nóng" nhất: mỗi lần quan sát tile là 1 upsert.

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| product_id | INTEGER | **PK** | |
| review_count | INTEGER | NULL | NULL = chưa biết; xem `review_status` |
| rating_avg | REAL | NULL | Tiles **không** hiện sao (đã kiểm chứng) → NULL cho đến khi có product page |
| review_status | TEXT | NOT NULL, CHECK trong enum | `NOT_YET_FETCHED` \| `NO_REVIEWS` \| `HAS_REVIEWS` \| `INACCESSIBLE` \| `MISSING` |
| confidence | REAL | NOT NULL DEFAULT 1.0 | <1.0 khi là suy luận (vd NO_REVIEWS từ "không hiện count", conf=0.9) |
| observed_at | DATE | NOT NULL | Lần quan sát gần nhất |
| source_surface | TEXT | NOT NULL | Tile nào cho count này |
| collector_version, parser_version | TEXT | NOT NULL | |

Ngữ nghĩa trạng thái (bắt buộc):
- `NOT_YET_FETCHED`: chưa từng quan sát (review_count NULL).
- `NO_REVIEWS`: đã quan sát tile, không hiện count → **suy luận** SP chưa có review
  (`review_count` NULL, confidence 0.9). Không ghi 0 để tránh ngộ nhận "đo được 0".
- `HAS_REVIEWS`: tile hiện count (đã chuẩn hóa `2.7K`→2700 lúc parse).
- `INACCESSIBLE`: 403/Cloudflare/timeout kéo dài (phân biệt với chưa fetch).
- `MISSING`: URL chết (404 / redirect khỏi /products/).

Dedup: PK `product_id`; upsert theo `observed_at` mới nhất thắng.

### 1.4 crawl_jobs — nhỏ

| Cột | Kiểu | Ràng buộc |
|---|---|---|
| job_id | INTEGER | **PK** AUTOINCREMENT |
| kind | TEXT NOT NULL | `sitemap_ingest` \| `collection_crawl` \| `merchant_crawl` \| `search_crawl` \| `compaction` \| `backup` \| `sheets_export` |
| target_desc | TEXT NOT NULL | Mô tả mục tiêu (vd `collection:dogecore/166998114364`) |
| status | TEXT NOT NULL | `QUEUED` \| `RUNNING` \| `PAUSED` \| `DONE` \| `FAILED` |
| created_at / started_at / finished_at | TIMESTAMP | NULL cho phép |
| stats_json | TEXT | `{"fetched":62,"new_products":12,...}` |

### 1.5 crawl_targets — cửa sổ queue ~1M dòng (KHÔNG 54,5M)

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| target_key | TEXT | **PK** | `p:<product_id>` \| `c:<collection_key>` \| `m:<merchant_key>` |
| target_type | TEXT | NOT NULL | `product` \| `collection` \| `merchant` |
| status | TEXT | NOT NULL, **INDEX(status, next_retry_at)** | `PENDING` \| `IN_PROGRESS` \| `DONE` \| `FAILED` \| `DEAD` |
| attempts | INTEGER | NOT NULL DEFAULT 0 | |
| next_retry_at | TIMESTAMP | NOT NULL DEFAULT now | Backoff hàm mũ: 2^attempts phút, max 24h |
| last_error | TEXT | NULL | Lỗi gần nhất (ngắn) |
| job_id | INTEGER | NULL, FK → crawl_jobs | |
| lease_until | TIMESTAMP | NULL | Worker giữ lease; sweeper thu hồi lease hết hạn → **sống sót VM restart** |

Thiết kế queue:
- Worker: `UPDATE ... SET status='IN_PROGRESS', lease_until=now+10ph WHERE target_key IN
  (SELECT ... WHERE status='PENDING' AND next_retry_at<=now LIMIT N)` — atomic claim.
- Sweeper (mỗi lần khởi động + định kỳ): `status='IN_PROGRESS' AND lease_until<now`
  → `PENDING`, attempts+1. Đây là cơ chế phục hồi sau restart/session end.
- `attempts>=8` → `DEAD` (không retry vô hạn); `DEAD` được review thủ công.
- **Không lưu URL** trong queue (tiết kiệm ~4 GB): resolve URL lúc dispatch bằng join
  `sitemap_urls` theo batch trong DuckDB. Trade-off đã ghi ở DATA_ARCHITECTURE.
- Prune: `DONE` quá 30 ngày → xóa (trạng thái SP đã có trong `product_review_state.observed_at`).

### 1.6 crawl_errors — sampled, append-only

| Cột | Kiểu | Ràng buộc |
|---|---|---|
| error_id | INTEGER **PK** AUTOINCREMENT | |
| target_key | TEXT NOT NULL, INDEX | |
| job_id | INTEGER NULL | |
| http_status | INTEGER NULL | 403/404/429/5xx/timeout=NULL |
| error_class | TEXT NOT NULL | `cloudflare` \| `http_403` \| `http_404` \| `timeout` \| `parse` \| `network` |
| observed_at | TIMESTAMP NOT NULL | |
| detail | TEXT NULL | Sample chi tiết (giới hạn 100/job/class) |

Aggregate đầy đủ trong `crawl_jobs.stats_json`; raw detail sampled để tiết kiệm ~10 GB.

### 1.7 dq_violations — sampled

| Cột | Kiểu | Ràng buộc |
|---|---|---|
| violation_id | INTEGER **PK** AUTOINCREMENT | |
| rule_id | TEXT NOT NULL, INDEX | FK logic → DATA_QUALITY_RULES |
| entity_type / entity_key | TEXT NOT NULL | |
| detail | TEXT NULL | |
| observed_at | TIMESTAMP NOT NULL | |

### 1.8 sheets_export_log — nhỏ

`(export_id PK, subset_name, spreadsheet_id, sheet_count, rows_total, exported_at,
source_manifest TEXT, status)` — truy vết bản Sheets nào từ manifest nào.

---

## 2. Parquet — lịch sử bất biến + serving

### 2.1 lake/sitemap_urls — 56,5M dòng, ghi 1 lần

`(url TEXT PK logic, url_type TEXT, shard INTEGER, discovered_at DATE)`
Partition: `url_type` (product|merchant|collection). Dedup: PK `url`.

### 2.2 lake/products — snapshots delta (base + deltas)

Mỗi dòng = **quan sát** 1 SP tại 1 thời điểm (không phải "SP hiện tại"):

`(product_id BIGINT, url TEXT, title TEXT, price DOUBLE, currency TEXT,
image_url TEXT, image_alt TEXT, review_count BIGINT NULL, rating_avg DOUBLE NULL,
observed_at DATE, source_surface TEXT, collector_version TEXT, parser_version TEXT)`
Partition: `crawl_date`. Không PK vật lý — dedup logic: `(product_id, crawl_date)`
giữ dòng `observed_at` lớn nhất khi compact.

`review_count` ở đây = số hiện trên tile **tại thời điểm quan sát** (kể cả NULL);
aggregate mới nhất luôn ở `product_review_state`.

### 2.3 lake/product_collections — edges n–n

`(product_id BIGINT, collection_key TEXT, position INTEGER NULL,
observed_at DATE, source_surface TEXT)`
Partition: `crawl_date`. Dedup logic: `(product_id, collection_key, crawl_date)`.
**Giữ toàn bộ quan hệ**: 1 SP trong nhiều collections (đã kiểm chứng), kể cả
collections generic (`all-products`) — không lọc lúc crawl, lọc lúc query.

### 2.4 lake/product_merchants — observations (1–n, có thể n–n)

`(product_id BIGINT, merchant_key TEXT, first_observed_at DATE, last_observed_at DATE,
evidence TEXT)` — evidence: `collection_tile`|`merchant_tile`|`search_tile`.
Sitemap products **không** có merchant key (đã kiểm chứng) nên đây là quan hệ
**quan sát được**, mang provenance. Cho phép nhiều merchant/SP (hiếm nhưng không cấm);
view current chọn `last_observed_at` lớn nhất.

### 2.5 lake/product_images — URL ảnh (KHÔNG binary)

`(product_id BIGINT, image_url TEXT, image_alt TEXT NULL, position INTEGER,
observed_at DATE, source_surface TEXT)`
PK logic: `(product_id, image_url)`. Partition: `crawl_date`.
Giai đoạn tiles: ~1 ảnh/SP. Mở rộng khi có product page. **Không tải binary.**

### 2.6 lake/reviews — SCHEMA SẴN, CHƯA CÓ DATA (Tier 3 bị chặn)

`(review_id TEXT, product_id BIGINT, rating SMALLINT NULL, title TEXT NULL,
body TEXT NULL, author TEXT NULL, created_at TIMESTAMP NULL,
verified_purchase BOOLEAN NULL, helpful_count BIGINT NULL, merchant_reply TEXT NULL,
observed_at DATE, source_surface TEXT)`
PK: `review_id = sha1(product_id|author|created_at|body[0:64])` — dedup khi crawl lại.
Partition: `crawl_date`. Mọi cột nội dung NULL-able vì field thực tế chưa kiểm chứng.

### 2.7 lake/field_changes — history field-level, append-only

`(entity_type TEXT, entity_key TEXT, field_name TEXT, old_value TEXT NULL,
new_value TEXT NULL, observed_at DATE, job_id BIGINT NULL, source_surface TEXT)`
Partition: `ym` (tháng). Values stringified (trade-off: schema ổn định, mất type-safety).
Ghi khi diff phát hiện đổi (so `lake/products` delta mới vs `current/`).

### 2.8 current/ — serving copy vật lý hóa (tái tạo được)

`(giống lake/products + bucket INTEGER)` — Partition: `ym` × `bucket` (256 buckets,
`bucket = hash(product_id) % 256`). Xem `PARTITION_AND_COMPACTION.md`.
Backup ưu tiên thấp (rebuild được từ `lake/`).

---

## 3. Quan hệ & cardinality

```
merchants 1───n collections 1───n product_collections n───1 products
merchants 1───n product_merchants n───1 products
products  1───n product_images
products  1───1 product_review_state
products  1───n reviews (future)
products  1───n field_changes (entity_type='product')
crawl_jobs 1───n crawl_targets, crawl_errors
```

Chi tiết ERD: `ENTITY_RELATIONSHIP.md`.

## 5. Sheets export spec — THIẾT KẾ, CHƯA TRIỂN KHAI ĐỒNG BỘ

Chính sách đã duyệt: trước mắt chỉ mirror **curated data** (vd top-reviewed mỗi niche);
mirror toàn corpus quyết định sau.

| Hạng mục | Spec |
|---|---|
| Cột (12, cố định) | `product_id, title, price, currency, review_count, rating_avg, merchant, collection, url, image_url, first_seen, last_seen` |
| Shard | **500.000 dòng/file** (≈6M cells < giới hạn 10M) |
| Tên file | `<subset>_part001`, `<subset>_part002`, ... |
| Ghi | `valueInputOption=RAW` (bắt buộc — USER_ENTERED hỏng số thập phân ở locale Việt) |
| Chuẩn bị | Đọc tên tab thật từ API (mặc định `Trang tính1`); pre-size grid trước khi ghi; freeze header |
| Nguồn | DuckDB `COPY ... TO CSV` từ `current/` + `product_review_state`, rồi upload batch |
| Truy vết | Mỗi lần export ghi `sheets_export_log` (subset, spreadsheet_id, source_manifest) |

Tốc độ ước lượng: ~10 batch calls/shard, 60 writes/phút → ~1–2 phút/shard.

---

## 4. Dedup tổng hợp

| Thực thể | Khóa dedup | Chiến lược |
|---|---|---|
| merchants/collections | PK tự nhiên | Upsert, `last_seen` mới thắng |
| products (lake) | `(product_id, crawl_date)` | Giữ `observed_at` lớn nhất lúc compact |
| product_review_state | `product_id` | Upsert, `observed_at` mới thắng |
| edges P–C / P–M | composite + ngày | Append observations, không xóa |
| images | `(product_id, image_url)` | Bỏ qua trùng |
| reviews (future) | `review_id` (sha1) | Bỏ qua trùng |
| conflicts (cùng key, giá trị khác) | — | Không coi là lỗi: ghi `field_changes`, bản mới nhất thắng ở current |
