# Data Dictionary — Shop App Crawler

**Phiên bản:** 1.0 | **Ngày:** 2026-10-15

Nguồn mỗi field: **[V]** = đã kiểm chứng thực tế · **[A]** = giả định (gắn nhãn) ·
**[D]** = tài liệu (help.shopify.com, chưa thấy data thật).

## Quy ước khóa

| Field | Kiểu | Nguồn | Ngữ nghĩa |
|---|---|---|---|
| `product_id` | INTEGER/BIGINT | **[V]** | ID số trong `/products/<id>/<slug>` (13–14 chữ số). Ổn định, unique toàn site → PK tự nhiên |
| `merchant_key` | TEXT | **[V]** | Token trong `/m/<token>` (vd `dogecore`). PK merchants |
| `collection_key` | TEXT | **[V]** | `<merchant_key>/<collection_id>` (vd `dogecore/166998114364`). PK collections |
| `target_key` | TEXT | **[A]** | `p:<product_id>` / `c:<collection_key>` / `m:<merchant_key>` — khóa queue |
| `review_id` | TEXT | **[A]** | `sha1(product_id\|author\|created_at\|body[0:64])` — dedup review crawl lại |

## Products

| Field | Kiểu | Null | Nguồn | Ngữ nghĩa |
|---|---|---|---|---|
| `url` | TEXT | no | **[V]** | URL đầy đủ tại thời điểm quan sát. Lưu ý: deep link serve tại `shop.com` nhưng canonical là `shop.app` — lưu canonical |
| `title` | TEXT | no | **[V]** | Từ tile (vd "how to live t-shirt"). Độ dài thực tế 20–150 ký tự |
| `price` | REAL | no | **[V]** | Đã parse `$31.50`→31.5. Thực tế $9.99–$98. Không gồm thuế/ship |
| `currency` | TEXT | no | **[V]** | `USD` (mọi tile quan sát) |
| `image_url` | TEXT | no | **[V]** | Ảnh chính tile (`cdn.shopify.com/...?width=800`). Strip param resize ngoài width |
| `image_alt` | TEXT | yes | **[V]** | Alt-text 20–200 ký tự; có khi chỉ là "T-shirt." |
| `review_count` | INTEGER | yes | **[V]** | Count trên tile **tại thời điểm T**; đã chuẩn hóa `2.7K`→2700 lúc parse. NULL = tile không hiện |
| `rating_avg` | REAL | yes | **[V]** | **Luôn NULL** — tiles không hiện sao (đã kiểm chứng). Chỉ có khi product page mở được |

## Review state

| Field | Kiểu | Null | Nguồn | Ngữ nghĩa |
|---|---|---|---|---|
| `review_status` | TEXT | no | **[V+A]** | `NOT_YET_FETCHED` chưa quan sát · `NO_REVIEWS` tile không count (**suy luận**, conf 0.9) · `HAS_REVIEWS` có count · `INACCESSIBLE` 403/challenge · `MISSING` URL chết |
| `confidence` | REAL | no | **[A]** | 1.0 = đo được; <1.0 = suy luận. Downstream lọc `>=0.95` nếu cần chắc |

## Merchants / Collections

| Field | Kiểu | Null | Nguồn | Ngữ nghĩa |
|---|---|---|---|---|
| `slug` | TEXT | no | **[V]** | Slug URL |
| `display_name` | TEXT | yes | **[V]** | Tên hiển thị (vd "Salt.xo") — có khi crawl merchant page |
| `shop_url` | TEXT | no | **[V]** | `https://shop.app/m/<token>` |
| `myshopify_domain` | TEXT | yes | **[V]** | `xxx.myshopify.com` — trích được từ 1 collection page mẫu |
| `apparel_prior` | REAL | no | **[A]** | Prior POD-apparel 0..1, khởi tạo từ collection scoring |
| `collection_id` | INTEGER | no | **[V]** | ID số trong URL collection |
| `intent_tier` | TEXT | yes | **[A]** | `garment`/`pod_intent`/`generic`/`other` — phục vụ priority scoring |
| `product_count_est` | INTEGER | yes | **[V]** | Từ lần crawl gần nhất (vd dogecore graphic-tees = 62) |

## Quan hệ

| Field | Kiểu | Nguồn | Ngữ nghĩa |
|---|---|---|---|
| `position` (edges) | INTEGER NULL | **[V]** | Vị trí tile trong collection/merchant page, nếu ghi nhận |
| `evidence` (P–M) | TEXT | **[V]** | `collection_tile`/`merchant_tile`/`search_tile` — vì sitemap products **không** có merchant key nên link này là quan sát được, không phải FK cứng |

## Crawl ops

| Field | Kiểu | Nguồn | Ngữ nghĩa |
|---|---|---|---|
| `kind` (job) | TEXT | **[A]** | `sitemap_ingest`/`collection_crawl`/`merchant_crawl`/`search_crawl`/`compaction`/`backup`/`sheets_export` |
| `status` (target) | TEXT | **[A]** | `PENDING`/`IN_PROGRESS`/`DONE`/`FAILED`/`DEAD` (`DEAD` sau 8 attempts) |
| `lease_until` | TIMESTAMP | **[A]** | Lease worker; sweeper thu hồi khi hết hạn → sống sót VM restart |
| `next_retry_at` | TIMESTAMP | **[A]** | Backoff 2^attempts phút, max 24h |
| `error_class` | TEXT | **[V]** | `cloudflare`/`http_403`/`http_404`/`timeout`/`parse`/`network` — từ quan sát thực tế |
| `stats_json` | TEXT | **[A]** | `{"fetched":62,"new_products":12,...}` |

## Provenance (mọi bảng)

| Field | Kiểu | Null | Ngữ nghĩa |
|---|---|---|---|
| `source_surface` | TEXT | no | `sitemap`/`collection_tile`/`merchant_tile`/`search_tile`/`product_page` |
| `observed_at` | DATE/TIMESTAMP | no | UTC |
| `collector_version` | TEXT | no | vd `crawler-0.3.0` |
| `parser_version` | TEXT | no | vd `tile-parser-0.2.1` — đổi khi logic parse count/giá đổi |

## Reviews (future — chưa data)

| Field | Kiểu | Null | Nguồn | Ngữ nghĩa |
|---|---|---|---|---|
| `rating` | SMALLINT | yes | **[D]** | 1–5 (kỳ vọng từ tài liệu Shop) |
| `body` | TEXT | yes | **[D]** | ≤1000 ký tự (tài liệu) |
| `verified_purchase` | BOOLEAN | yes | **[D]** | Shop reviews là verified-purchase-only (tài liệu) |
| `merchant_reply` | TEXT | yes | **[D]** | Merchant được reply (tài liệu) |

Không field nào ở bảng reviews được coi là "đã kiểm chứng" cho đến khi Tier 3 mở.
