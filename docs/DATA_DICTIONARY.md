# Data Dictionary — Shop App Crawler

**Phiên bản:** 1.2 | **Ngày:** 2026-10-15

Nguồn: **[V]** kiểm chứng thực tế · **[A]** giả định · **[D]** tài liệu (chưa data thật).
v1.2: `observation_id` · generation manifest · `ingest_batches` · `explore_budget_pct=15`.

**Mọi cột thời gian quan sát là TIMESTAMP UTC** (microsecond khi có). Partition dùng
cột DATE suy ra (`crawl_date`, `ym`).

## Khóa

| Field | Kiểu | Nguồn | Ngữ nghĩa |
|---|---|---|---|
| `product_id` | INTEGER/BIGINT | **[V]** | ID số `/products/<id>/` (13–14 chữ số) → PK tự nhiên |
| `merchant_key` | TEXT | **[V]** | Token `/m/<token>` → PK merchants |
| `collection_key` | TEXT | **[V]** | `<merchant_key>/<collection_id>` → PK collections |
| `target_key` | TEXT | **[A]** | `p:<product_id>` / `c:<collection_key>` / `m:<merchant_key>` |
| `review_id` | TEXT | **[A]** | **Surrogate** `rv_<uuid4hex>`, luôn có — không suy từ nội dung |
| `observation_id` | TEXT | **[A]** | **Định danh quan sát ổn định** `<job_id>:<batch_seq>:<row_seq>` (v1.2). Thứ tự xác định: `ORDER BY observed_at, observation_id` |
| `generation_id` | TEXT | **[A]** | `gen_<NNN>` — một lần publication `current/` (v1.2) |

## Products (§2 PARQUET_SCHEMAS)

| Field | Null | Nguồn | Ngữ nghĩa |
|---|---|---|---|
| `url` | no | **[V]** | Canonical `shop.app` (deep link serve tại `shop.com` nhưng lưu canonical) |
| `title` | no | **[V]** | 20–150 ký tự thực tế |
| `price` | no | **[V]** | $9.99–$98 quan sát; chưa gồm thuế/ship |
| `currency` | no | **[V]** | `USD` |
| `image_url` / `image_alt` | no/yes | **[V]** | `cdn.shopify.com`; alt 20–200 ký tự |
| `review_count` | yes | **[V]** | Tại thời điểm quan sát; đã chuẩn hóa `2.7K`→2700 |
| `rating_avg` | yes | **[V]** | Luôn NULL — tiles không hiện sao |
| `observed_at` | no | **[V]** | **TIMESTAMP** — nhiều quan sát/ngày giữ hết (v1.1) |

## Review state (v1.1 — 2 trục)

| Field | Null | Nguồn | Ngữ nghĩa |
|---|---|---|---|
| `review_status` | no | **[V+A]** | **DATA:** `UNKNOWN` chưa từng thấy data · `NO_REVIEWS` tile không count (**suy luận**, conf 0.9) · `HAS_REVIEWS` có count |
| `fetch_status` | no | **[V]** | **ACCESS:** `NOT_YET_FETCHED`/`OK`/`HTTP_403`/`HTTP_404`/`TIMEOUT`/`CHALLENGE`/`ERROR`. Fail **không** đụng data columns |
| `confidence` | no | **[A]** | 1.0 đo được; <1.0 suy luận |
| `last_success_at` | yes | **[V]** | Lần data OK gần nhất |
| `last_attempt_at` | no | **[V]** | Lần thử fetch gần nhất (mọi kết quả) |

## Scheduling (design)

| Field | Nguồn | Ngữ nghĩa |
|---|---|---|
| `collections.priority_score` | **[A]** | Collection Priority Score; công thức tương lai, versioned |
| `score_version` / `score_updated_at` | **[A]** | Truy vết công thức |
| `crawl_count` / `last_crawled_at` | **[V]** | Phục vụ exploration (ưu tiên chưa crawl) |
| `merchants.merchant_score` | **[A]** | Merchant Feedback từ yield collections đã crawl |
| `collection_crawl_stats.reward_r1/10/50/100` | **[V]** | Vector reward R_T = unique reviewed / requests × 1000 |
| `crawl_targets.priority` | **[A]** | Scheduler `ORDER BY priority DESC` + `explore_budget_pct` chống starvation |
| `crawl_policy.explore_budget_pct` | **[A]** | Mặc định **15** (APPROVED), cấu hình được, hiệu chỉnh sau benchmark |

## Ingest & recovery (v1.2)

| Field | Nguồn | Ngữ nghĩa |
|---|---|---|
| `ingest_batches.batch_key` | **[A]** | `<job_id>:<batch_seq>` — checkpoint crash-safe |
| `ingest_batches.status` | **[A]** | `STAGED` → `PARQUET_DONE` → `COMPLETE` |
| `observed_at` (products) | **[V]** | **Gán lúc fetch**, ingest giữ nguyên → replay an toàn |

## Review identity (v1.1 — không hash-mặc-định)

| Field | Null | Ngữ nghĩa |
|---|---|---|
| `review_key_platform` | yes | ID platform nếu từng thấy |
| `author_norm` | yes | Chuẩn hóa để match khi thiếu ID |
| `content_sha256` | yes | Tín hiệu, không phải ID |
| `identity_method` | no | `platform_id` > `author_time` > `content_fallback` > `surrogate_only` |
| `identity_confidence` | no | 1.0 → 0.3 |
| `version` / `supersedes` | no/yes | Nội dung bị sửa → version+1, trỏ version cũ |

## Merchants / Collections / Quan hệ / Crawl ops

Không đổi so v1.0 trừ: `first_seen`/`last_seen`/`first_observed_at`/`last_observed_at`
→ TIMESTAMP; thêm các cột scheduling ở trên. Xem DATABASE_SCHEMA.md.

## Reviews (future)

Mọi field nội dung **[D]** (tài liệu Shop), chưa kiểm chứng trên data thật.
`rating` 1–5, `body` ≤1000 ký tự, `verified_purchase` — tất cả nullable.
