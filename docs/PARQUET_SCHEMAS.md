# Parquet Schemas — Shop App Crawler

**Phiên bản:** 1.0 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt

Mọi dataset: Snappy hoặc ZSTD (mặc định **ZSTD level 3** — đo được 3,7x trên dữ liệu
thật high-cardinality). File **bất biến**. `schema_version` ghi trong metadata mỗi file
(xem `SCHEMA_EVOLUTION.md`). Kiểu Arrow ghi trong ngoặc.

Quy ước NULL: mọi cột quan sát được đều nullable trừ khóa và cột provenance bắt buộc.

---

## 1. `lake/sitemap_urls/` — vũ trụ discovery (ghi 1 lần)

Partition: `url_type` (hive: `url_type=product/`).

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| url | string | no | PK logic. `https://shop.app/products/<id>/<slug>` |
| url_type | string | no | `product` \| `merchant` \| `collection` (partition) |
| shard | int32 | no | Shard sitemap gốc (0..1089 products) |
| discovered_at | date32 | no | Ngày ingest sitemap |

Khối lượng (đo/giả định): 56,5M URLs × ~85 B raw → **~0,6 GB** ZSTD (giả định nén 10x
nhờ tiền tố URL lặp — gắn nhãn giả định).

## 2. `lake/products/` — snapshots delta (base + deltas)

Mỗi dòng = **một quan sát** 1 SP tại 1 thời điểm. Partition: `crawl_date`.

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| product_id | int64 | no | ID số từ URL — dedup key |
| url | string | no | URL đầy đủ tại thời điểm quan sát |
| title | string | no | Từ tile (vd "how to live t-shirt") |
| price | double | no | Đã parse `$31.50` → 31.5 |
| currency | string | no | `USD` (quan sát thực tế) |
| image_url | string | no | Ảnh chính của tile (`cdn.shopify.com`, đã strip param resize ngoài `width`) |
| image_alt | string | yes | Alt-text (20–200 ký tự thực tế) |
| review_count | int64 | yes | Count trên tile tại T; NULL nếu tile không hiện |
| rating_avg | double | yes | **Luôn NULL** đến khi product page mở được (tiles không hiện sao) |
| observed_at | date32 | no | |
| source_surface | string | no | `collection_tile` \| `merchant_tile` \| `search_tile` |
| collector_version | string | no | |
| parser_version | string | no | |

Dedup logic lúc compact: `(product_id, crawl_date)` giữ `observed_at` lớn nhất.
Khối lượng: 54,5M × **149 B** (đo) ≈ **8,1 GB** cho base snapshot.

## 3. `lake/product_collections/` — edges n–n

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| product_id | int64 | no | |
| collection_key | string | no | `<merchant_key>/<collection_id>` |
| position | int32 | yes | Vị trí tile trong collection (nếu ghi nhận được) |
| observed_at | date32 | no | |
| source_surface | string | no | |

Partition: `crawl_date`. Dedup: `(product_id, collection_key, crawl_date)`.
Khối lượng: ~109M edges (giả định ~2/SP) × ~12 B ≈ **1,3–1,5 GB**.

## 4. `lake/product_merchants/` — observations P–M

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| product_id | int64 | no | |
| merchant_key | string | no | |
| first_observed_at | date32 | no | |
| last_observed_at | date32 | no | |
| evidence | string | no | `collection_tile` \| `merchant_tile` \| `search_tile` |

Không partition theo ngày (bảng observations gộp dần, rewrite theo merchant batch
nhỏ khi cần — hoặc append và dedup lúc đọc; xem PARTITION_AND_COMPACTION).
Khối lượng: 54,5M × ~30 B ≈ **1,6 GB** (giả định).

## 5. `lake/product_images/` — URL ảnh, KHÔNG binary

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| product_id | int64 | no | |
| image_url | string | no | PK logic cùng product_id |
| image_alt | string | yes | |
| position | int32 | no | 0 = ảnh chính |
| observed_at | date32 | no | |
| source_surface | string | no | |

Partition: `crawl_date`. Khối lượng: ~1 ảnh/SP giai đoạn tiles → 54,5M × ~50 B ≈
**2,7 GB** (giả định; tăng khi product page mở được nhiều ảnh).

## 6. `lake/reviews/` — SCHEMA SẴN, CHƯA CÓ DATA

Mở khi Tier 3 (review text) có đường truy cập hợp lệ. Mọi cột nội dung nullable
vì field thực tế **chưa kiểm chứng** — không tưởng tượng API fields.

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| review_id | string | no | PK: `sha1(product_id\|author\|created_at\|body[0:64])` — dedup crawl lại |
| product_id | int64 | no | |
| rating | int8 | yes | 1–5 (kỳ vọng; chưa kiểm chứng) |
| title | string | yes | |
| body | string | yes | Giới hạn Shop ≤1000 ký tự (từ help.shopify.com — tài liệu, chưa thấy data thật) |
| author | string | yes | Ẩn danh hóa nếu cần |
| created_at | timestamp | yes | |
| verified_purchase | boolean | yes | Shop reviews là verified-purchase-only (tài liệu) |
| helpful_count | int64 | yes | |
| merchant_reply | string | yes | |
| observed_at | date32 | no | |
| source_surface | string | no | |

Partition: `crawl_date`. Khối lượng: **kịch bản** — 5% SP × 15 reviews ≈ 3 GB;
20% × 30 reviews ≈ 25 GB (xem DATA_ARCHITECTURE rủi ro #5).

## 7. `lake/field_changes/` — history field-level, append-only

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| entity_type | string | no | `product` \| `collection` \| `merchant` |
| entity_key | string | no | product_id / collection_key / merchant_key (stringified) |
| field_name | string | no | `price` \| `title` \| `review_count` \| ... |
| old_value | string | yes | Stringified (trade-off: schema ổn định) |
| new_value | string | yes | |
| observed_at | date32 | no | |
| job_id | int64 | yes | |
| source_surface | string | no | |

Partition: `ym` (tháng). Khối lượng: giả định 3% SP crawl/ngày đổi × 1M crawl/ngày
→ ~30k diffs/ngày × ~150 B ≈ **1,6 GB/năm**.

## 8. `current/ym=*/bucket-*.parquet` — serving copy (tái tạo được)

Schema = `lake/products/` + `bucket int32`. Partition hive: `ym` × `bucket`
(256 buckets, `bucket = hash(product_id) % 256`).
Khối lượng: ≈ base **8 GB** ở 54,5M. **Tái tạo được từ `lake/`** → backup ưu tiên thấp.
Xem `PARTITION_AND_COMPACTION.md`.

## Quy tắc chung

- Không FK vật lý trong Parquet — toàn vẹn tham chiếu do DQ job kiểm tra.
- Không lồng mảng quan hệ trong bảng products — quan hệ nằm ở bảng edges.
- Mọi thay đổi schema: additive-only, xem `SCHEMA_EVOLUTION.md`.
