# Parquet Schemas — Shop App Crawler

**Phiên bản:** 1.2 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt (vòng cuối)

v1.2: thêm `observation_id` (định danh quan sát ổn định); `current/` publication
nguyên tử qua generation manifest.

v1.1: mọi `observed_at` là **TIMESTAMP UTC** (microsecond) — phân biệt nhiều quan sát
cùng ngày. Partition dùng cột DATE suy ra (`crawl_date`, `ym`).

Mặc định **ZSTD level 3** (đo 3,7x trên dữ liệu thật high-cardinality). File **bất biến**.
`schema_version` trong metadata mỗi file. Không field nào được coi "đã kiểm chứng"
trừ khi gắn **[V]**.

---

## 1. `lake/sitemap_urls/` — vũ trụ discovery

Partition: `url_type`. `(url **[V]** PK logic, url_type, shard INT32, discovered_at TIMESTAMP)`
~56,5M URLs → **~0,6 GB** (giả định nén 10x).

## 2. `lake/products/` — snapshots: GIỮ MỌI QUAN SÁT

Mỗi dòng = một quan sát. **Không dedup lúc ingest** (v1.1 #2).

| Cột | Kiểu | Null | Nguồn | Ghi chú |
|---|---|---|---|---|
| observation_id | string | no | **[A]** | **Định danh ổn định**: `<job_id>:<batch_seq>:<row_seq>` (vd `1042:000137:000012`). Thứ tự xác định: `ORDER BY observed_at, observation_id` |
| product_id | int64 | no | **[V]** | Dedup key lúc compact |
| url / title / price / currency | string,string,double,string | no | **[V]** | Như v1.0 |
| image_url / image_alt | string | no/yes | **[V]** | |
| review_count | int64 | yes | **[V]** | Tại thời điểm quan sát; NULL nếu tile không hiện |
| rating_avg | double | yes | **[V]** | Luôn NULL đến khi product page mở được |
| observed_at | timestamp | no | **[V]** | **Gán lúc fetch**, ingest giữ nguyên → replay an toàn |
| crawl_date | date32 | no | suy ra | Partition (từ observed_at) |
| source_surface / collector_version / parser_version | string | no | | |

Dedup chỉ ở compaction: `(product_id)` + `ORDER BY observed_at DESC`.
Base 54,5M × **149 B** (đo) ≈ **8,1 GB**.

## 3. `lake/product_collections/` — edges n–n

`(product_id, collection_key, position INT32 NULL, observation_id TEXT NULL,
observed_at TIMESTAMP, crawl_date DATE [partition], source_surface)`.
Dedup: `(product_id, collection_key, crawl_date)`.
`observation_id` trỏ về quan sát tile đã sinh ra edge (traceability, v1.2).
~109M edges ≈ **1,3–1,5 GB**.

## 4. `lake/product_merchants/` — observations

`(product_id, merchant_key, first_observed_at TIMESTAMP, last_observed_at TIMESTAMP,
evidence)`. ~54,5M × 30 B ≈ **1,6 GB** (giả định).

## 5. `lake/product_images/` — URL only

`(product_id, image_url, image_alt NULL, position INT32, observed_at TIMESTAMP,
crawl_date DATE [partition], source_surface)`. PK logic `(product_id, image_url)`.
~1 ảnh/SP → **2,7 GB** (giả định).

## 6. `lake/reviews/` — identity nhiều tầng (v1.1 #5)

Schema sẵn, **chưa data**. Không mặc định hash = ID ổn định.

| Cột | Kiểu | Null | Ghi chú |
|---|---|---|---|
| review_id | string | no | **PK surrogate** `rv_<uuid4hex>` — luôn có, không suy từ nội dung |
| review_key_platform | string | yes | ID platform nếu từng thấy |
| product_id | int64 | no | |
| author / author_norm | string | yes | `author_norm`: lowercase+strip, phục vụ match |
| created_at | timestamp | yes | NULL khi thiếu |
| content_sha256 | string | yes | Tín hiệu, không phải ID |
| identity_method | string | no | `platform_id`→`author_time`→`content_fallback`→`surrogate_only` |
| identity_confidence | float | no | 1.0 → 0.3 theo method |
| version | int32 | no | Tăng khi nội dung bị **sửa** (cùng identity, khác hash) |
| supersedes | string | yes | `review_id` version trước |
| rating/title/body | int8/string/string | yes | Chưa kiểm chứng field thật |
| verified_purchase/helpful_count/merchant_reply | boolean/int64/string | yes | Từ tài liệu Shop (chưa data) |
| observed_at | timestamp | no | |
| crawl_date | date32 | no | Partition |
| source_surface | string | no | |

View current: `MAX(version)` mỗi identity. Kịch bản dung lượng: 5%×15 ≈ 3 GB;
20%×30 ≈ 25 GB.

## 7. `lake/field_changes/` — append-only, diff theo chuỗi TIMESTAMP

`(entity_type, entity_key, field_name, old_value STRING NULL, new_value STRING NULL,
observed_at TIMESTAMP, ym STRING [partition], job_id INT64 NULL, source_surface)`.
**Quy tắc v1.1:** diff trên chuỗi quan sát liên tiếp `(product_id, observed_at)` —
mọi thay đổi intraday đều ghi, không gộp ngày. ~**1,6 GB/năm** (giả định).

## 8. `current/` — ĐÚNG 1 DÒNG/product_id + PUBLICATION NGUYÊN TỬ (v1.2)

```
current/
  generations/
    gen_0007/bucket-000.parquet … bucket-255.parquet   # chỉ bucket được rewrite
  manifests/
    manifest_gen_0007.json    # đủ 256 buckets (bucket không đổi trỏ về gen cũ)
  current_latest.json         # {"generation": "gen_0007"} — con trỏ nguyên tử
```

- Schema mỗi bucket = §2 + `bucket INT32`. **Không partition ym.**
- Mỗi generation là snapshot nhất quán; publication = atomic rename
  `current_latest.json`. Crash giữa compaction → reader vẫn thấy generation cũ.
- Query resolve file list từ manifest của generation hiện tại (không glob mù).
- ~**8 GB** ở 54,5M, **tái tạo được** → backup ưu tiên thấp (nhưng manifest
  generation phải có trong backup manifest — xem BACKUP_RESTORE_DESIGN).

## Quy tắc chung

- Không FK vật lý trong Parquet — DQ job kiểm tra orphan.
- Không mảng quan hệ trong products — edges ở bảng riêng.
- Schema additive-only (SCHEMA_EVOLUTION.md). Đổi hàm hash bucket = migration.
