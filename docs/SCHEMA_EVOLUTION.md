# Schema Evolution & Migrations — Shop App Crawler

**Phiên bản:** 1.0 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt

## 1. Nguyên tắc

1. **Additive-only:** chỉ thêm cột nullable / bảng mới. Không đổi kiểu cột đã có,
   không xóa cột, không rename (rename = thêm cột mới + deprecate cột cũ).
2. **Mọi file Parquet mang `schema_version`** trong metadata (vd `schema_version=1.0`).
   Reader bỏ qua cột lạ, điền NULL cho cột thiếu → đọc được file cũ/mới lẫn lộn.
3. **SQLite migrations có versioned scripts** (`migrations/0001_*.sql`), mỗi script
   ghi 1 dòng vào `schema_migrations(version, applied_at)`. Chạy trong transaction.
4. **Rebuild luôn khả thi:** `current/` rebuild được từ `lake/` (replay deltas) —
   migration Parquet = ghi lại partition nóng, không sửa file cũ.

## 2. Quy trình thay đổi

```
1. Đề xuất trong docs (ghi lý do, ảnh hưởng dung lượng/query).
2. User duyệt (schema là quyết định kiến trúc).
3. SQLite: viết migration script → review → chạy → ghi schema_migrations.
   Parquet: bump schema_version → writer mới ghi cột mới → reader tương thích ngược.
4. Cập nhật DATA_DICTIONARY.md + PARQUET_SCHEMAS.md/SQLITE_SCHEMA.sql trong cùng commit.
5. Backup manifest ghi schema_version để restore đúng reader.
```

## 3. Các kịch bản thường gặp

| Thay đổi | Cách làm |
|---|---|
| Thêm field tile mới (vd `badge`) | Thêm cột nullable vào `lake/products`; schema_version 1.1 |
| Review text mở (Tier 3) | Bảng `lake/reviews` đã sẵn — chỉ bắt đầu ghi data, không đổi schema |
| Đổi hàm hash bucket | Migration lớn: dual-write 2 bucket schemes 1 tháng → backfill → chuyển reader. **Tránh nếu có thể** |
| Tách bảng SQLite quá lớn | Tạo bảng mới + view UNION tương thích → migrate dần |
| Xóa field | Không xóa vật lý: ngừng ghi, đánh `deprecated` trong dictionary, giữ cột để đọc file cũ |

## 4. Rebuild current state từ immutable events

```
lake/products (base + mọi delta, bất biến)
   │ replay theo (product_id, observed_at)
   ▼
dedup từng bucket (hash % 256) ──► current/bucket-*.parquet
```

Rebuild là thao tác **đọc + ghi mới**, không sửa dữ liệu gốc → an toàn chạy lại.
Dùng khi: đổi logic dedup, nghi corruption ở `current/`, hoặc sau restore chỉ có `lake/`.

## 5. Tương thích engine tương lai

Interface contracts (DATA_ARCHITECTURE mục 6) là **versioned views**, không phải bảng:
`v_niche_input_v1`, `v_review_input_v1`, ... Engine đọc qua view versioned →
đổi schema nội bộ không vỡ engine, chỉ bump view version.

## 6. Lịch sử thay đổi schema

| Phiên bản | Ngày | Thay đổi |
|---|---|---|
| 1.0 | 2026-10-15 | Bản đầu. |
| 1.1 | 2026-10-15 | Design review: (1) `observed_at` DATE→TIMESTAMP UTC mọi nơi; (2) tách `fetch_status`/`review_status`; (3) thêm `collection_crawl_stats`, `crawl_policy`, `priority`/`priority_score`/`merchant_score`; (4) review identity nhiều tầng + versioning; (5) `current/` bỏ partition ym → đúng 1 dòng/product_id (atomic per-bucket replace). Không breaking change với dữ liệu vì chưa có dữ liệu production. |
| 1.2 | 2026-10-15 | Final review: (1) `observation_id` ổn định + total order `(observed_at, observation_id)`; idempotent replay theo tên file batch + `ingest_batches`; (2) R14 viết lại — NULL hợp lệ cho cả UNKNOWN và NO_REVIEWS, phân biệt bằng confidence; giảm thật được ghi nhận; (3) `current/` publication nguyên tử qua generation manifest (`current_latest.json`); (4) recovery protocol staging→parquet→sqlite, lake là source of truth replay được; (5) `explore_budget_pct=15` mặc định; (6) R19/R20/R21; (7) `ACCESS_POLICY_AND_RISKS.md` tách riêng. |
