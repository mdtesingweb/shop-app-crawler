# Data Quality Rules — Shop App Crawler

**Phiên bản:** 1.2 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt (vòng cuối)

v1.2: R14 viết lại — hết mâu thuẫn với `NO_REVIEWS` suy luận; thêm R19 (generation
consistency), R20 (observation ordering), R21 (ingest batch completeness).

Chạy bằng DuckDB sau mỗi crawl job + định kỳ toàn corpus (theo partition).
Kết quả vào `dq_violations` (SQLite, sampled) + tổng hợp vào `crawl_jobs.stats_json`.

## 1. Rules

| ID | Phạm vi | Rule | Mức | Hành động khi fail |
|---|---|---|---|---|
| R1 | products | `(product_id, observed_at)` unique trong `lake/` (TIMESTAMP cho phép nhiều quan sát/ngày) | ERROR | Trùng timestamp = ingest bug, giữ 1, log |
| R2 | product_collections | Mọi `product_id` tồn tại trong products (orphan check) | ERROR | Ghi `dq_violations`, giữ edge (có thể SP chưa ingest) |
| R3 | products/state | `review_count IS NULL OR review_count >= 0` | ERROR | Quarantine dòng |
| R4 | products | `price > 0 AND price < 100000` | ERROR | Quarantine (giá tile thực tế $9.99–$98) |
| R5 | products | `url` match `^https://shop\.app/products/[0-9]+/` | ERROR | Quarantine |
| R6 | collections | `merchant_key` tồn tại trong merchants (orphan check) | ERROR | Ghi violations |
| R7 | product_merchants | `product_id` + `merchant_key` tồn tại | WARN | Giữ observation (có thể đến trước product ingest) |
| R8 | products | `title` không rỗng, < 500 ký tự | WARN | Giữ, gắn cờ |
| R9 | product_images | `(product_id, image_url)` unique | ERROR | Dedup bỏ qua |
| R10 | reviews (future) | `review_id` unique; `rating BETWEEN 1 AND 5` | ERROR | Dedup / quarantine |
| R11 | field_changes | `old_value != new_value` | WARN | Bỏ qua diff rỗng (parser normalize) |
| R12 | crawl_targets | Không có `IN_PROGRESS` quá hạn lease sau sweeper | ERROR | Sweeper tự phục hồi (mục 2) |
| R13 | freshness | `max(last_attempt_at)` của `product_review_state` ≤ 48h so với lịch crawl | WARN | Báo động pipeline đứng |
| R14 | state | (a) `review_status='HAS_REVIEWS'` ⟹ `review_count IS NOT NULL`; (b) `review_status='UNKNOWN'` ⟹ `review_count IS NULL`; (c) `review_status='NO_REVIEWS'` ⟹ `review_count IS NULL AND confidence < 1.0` (đánh dấu suy luận — **không mâu thuẫn** vì NULL hợp lệ cho cả UNKNOWN và NO_REVIEWS, phân biệt bằng confidence); (d) `review_status IN ('HAS_REVIEWS','NO_REVIEWS')` ⟹ `last_success_at IS NOT NULL`; (e) `fetch_status != 'OK'` ⟹ data columns không đổi so với lần success (so `last_success_at`) | ERROR | Vi phạm = ingest bug |
| R15 | current/ | `COUNT(*) == COUNT(DISTINCT product_id)` **trong generation đang live** | ERROR | Writer bug — dừng compaction, điều tra |
| R16 | state | `NO_REVIEWS` luôn có `confidence < 1.0` (không ngộ nhận suy luận thành sự thật) | ERROR | — |
| R17 | reviews (future) | `identity_method` hợp lệ; `content_fallback`/`surrogate_only` gắn cờ duplicate candidate | WARN | Không mặc định hash = ID |
| R18 | missing-field | Tỷ lệ NULL `title`/`price`/`image_url` = 0% | ERROR | Không field bắt buộc nào NULL âm thầm |
| R19 | current/ | Generation manifest: đủ 256 buckets, mọi file tồn tại, `current_latest.json` trỏ generation có manifest | ERROR | Publication dở dang — không cho query |
| R20 | lake/ | Không trùng `(product_id, observed_at, observation_id)`; thứ tự `(observed_at, observation_id)` là total order | ERROR | Ingest bug |
| R21 | ingest | Không có dòng `ingest_batches` ở `STAGED`/`PARQUET_DONE` quá 24h chưa `COMPLETE` (trừ job đang chạy) | WARN | Crash chưa phục hồi — chạy recovery |

## 2. Checks vận hành

**Lưu ý (APPROVED):** review count **giảm thật không phải violation** — R14 chỉ kiểm tra
tính nhất quán trạng thái, không áp đặt đơn điệu tăng. Giảm được ghi nhận nguyên vẹn
và log vào `field_changes`.

- **Orphan detection:** query R2/R6/R7 mỗi lần ingest batch — orphan được **giữ lại**
  (không xóa), vì ingest có thể đến không theo thứ tự (edge về trước product).
  Orphan tồn tại > 7 ngày → điều tra.
- **Dedup checks:** đếm `COUNT(*) - COUNT(DISTINCT product_id)` mỗi snapshot ngày (R1);
  cùng `product_id` khác `title`/`price` giữa 2 observations → không phải lỗi,
  ghi `field_changes` (thay đổi thật) — phân biệt "trùng lặp" với "thay đổi".
- **Missing-field monitoring:** dashboard tỷ lệ NULL theo field/ngày; spike đột ngột
  = parser hỏng (vd tile đổi layout), không phải data thật.
- **Parser version guard:** nếu `parser_version` đổi, chạy R1–R14 trên sample 10k dòng
  trước khi cho ingest bulk.

## 3. KPI thu thập (đo mỗi job, lưu `stats_json`)

| KPI | Định nghĩa | Target (giả định, hiệu chỉnh sau 1M dòng thật) |
|---|---|---|
| `fetch_success_rate` | `fetched / targets` | > 95% |
| `tile_yield` | SP mới / collection crawl | theo dõi xu hướng |
| `review_coverage` | `HAS_REVIEWS+NO_REVIEWS / products_observed` | > 90% (đã quan sát ⇒ có trạng thái) |
| `review_yield_R10` | SP có review_count ≥ 10 / 1000 requests | theo dõi (KPI chính Collection Priority Scoring) |
| `change_rate` | diffs / products_crawled / ngày | ~3% (giả định) |
| `inaccessible_rate` | `INACCESSIBLE / targets` | < 5%; spike = Cloudflare đổi chính sách |
| `dedup_ratio` | 1 − (unique products / tile observations) | theo dõi overlap collections |
| `queue_starvation` | số lần worker refill vì hết PENDING | = 0 trong job bình thường |

## 4. Quarantine

Dòng fail ERROR → `quarantine/` (Parquet, partition theo ngày + rule_id), không vào
`current/`. Review thủ công trước khi cho nhập lại. Không bao giờ xóa âm thầm.
