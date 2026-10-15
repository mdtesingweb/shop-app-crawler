# Partition, Bucketing, Compaction & DuckDB Patterns

**Phiên bản:** 1.1 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt

Máy mục tiêu: 2 CPU, 7,7 GB RAM (**không swap**), SSD 100 GB.
v1.1: `current/` **không partition theo tháng** — đúng 1 file/bucket, đúng 1 dòng/SP
về mặt vật lý. Lịch sử theo thời gian nằm ở `lake/` (bất biến).

---

## 1. Partitioning

```
lake/
  sitemap_urls/url_type=*/part-*.parquet
  products/crawl_date=YYYY-MM-DD/part-*.parquet   # crawl_date DATE suy từ observed_at TS
  product_collections/crawl_date=*/part-*.parquet
  product_images/crawl_date=*/part-*.parquet
  reviews/crawl_date=*/part-*.parquet              # future
  field_changes/ym=YYYY-MM/part-*.parquet
  product_merchants/merchant_shard=*/part-*.parquet

current/
  bucket-000.parquet … bucket-255.parquet          # 256 files, KHÔNG ym
  current_manifest.json                            # {bucket,file,rows,max_observed_at,compacted_at}
```

- `bucket = hash(product_id) % 256`, hash ổn định (FNV-1a — đổi hàm = migration).
- Mỗi bucket ở 54,5M ≈ 213k dòng — vừa RAM để dedup/sort cục bộ.
- File target 128–256 MB.

## 2. Compaction — đúng 1 dòng/product_id (v1.1)

**Bất biến:** sau mỗi lần compact bucket `b` thành công, file `bucket-b.parquet`
chứa **đúng một dòng cho mỗi product_id** thuộc bucket. Writer đảm bảo bằng:

```
cho mỗi bucket b (độc lập, idempotent):
    đọc:  current/bucket-b.parquet                       (nếu có)
        + lake/products/crawl_date=<k ngày qua>/part-*.parquet
          với predicate pushdown product_id % 256 == b     (skip file không liên quan)
    dedup: ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY observed_at DESC) = 1
           -- observed_at là TIMESTAMP: nhiều quan sát cùng ngày không mất (v1.1 #2)
    ghi:  current/bucket-b.parquet.tmp → rename nguyên tử → bucket-b.parquet
    cập nhật current_manifest.json cho bucket b
```

- Crash giữa chừng: file cũ còn nguyên (rename nguyên tử); chạy lại idempotent.
- Không bao giờ full-rewrite 256 buckets cùng lúc trừ khi cần — compaction thường
  chỉ chạy các bucket có delta mới (đọc `current_manifest.json` so `max_observed_at`).
- Chi phí: 1 bucket ≈ 213k + delta dòng → vài giây (đo 194k dòng/s in-RAM).
- `field_changes` được sinh **trước** compaction bằng cách diff chuỗi quan sát liên
  tiếp theo `(product_id, observed_at)` — mọi thay đổi intraday đều ghi nhận.

Vì sao bỏ `ym` ở current/ (v1.0): SP cập nhật qua nhiều tháng sẽ xuất hiện ở nhiều
partition tháng → "bản ghi hiện tại" thành nhiều dòng, phải dedup lúc query.
Thiết kế mới: lịch sử ở `lake/`, hiện tại ở `current/` — mỗi nơi một nhiệm vụ.

## 3. DuckDB query patterns

```sql
-- 0. Attach (1 lần/session)
ATTACH 'data/state/crawl_state.db' AS s;

-- 1. Point lookup — KHÔNG cần dedup (writer đã đảm bảo)
SELECT * FROM read_parquet('data/current/bucket-*.parquet')
WHERE product_id = 10269120594195;

-- 2. Lịch sử giá/review của 1 SP (intraday đầy đủ)
SELECT observed_at, price, review_count, source_surface
FROM read_parquet('data/lake/products/crawl_date=*/part-*.parquet',
                  hive_partitioning=true)
WHERE product_id = 10269120594195
ORDER BY observed_at;   -- TIMESTAMP: thấy mọi lần đổi trong ngày

-- 3. Aggregate review theo merchant (dùng SQLite state — nhanh)
SELECT m.merchant_key, COUNT(*) n,
       SUM(CASE WHEN r.review_status='HAS_REVIEWS' THEN 1 ELSE 0 END) n_reviewed
FROM s.product_review_state r
JOIN read_parquet('data/lake/product_merchants/*/*.parquet') pm
  ON pm.product_id = r.product_id
JOIN s.merchants m ON m.merchant_key = pm.merchant_key
GROUP BY 1;

-- 4. Top collections theo reward (priority scheduling)
SELECT c.collection_key, c.priority_score,
       SUM(s.reward_r10) AS r10_total, SUM(s.requests_used) AS req
FROM s.collections c
JOIN s.collection_crawl_stats s ON s.collection_key = c.collection_key
GROUP BY 1, 2 ORDER BY r10_total DESC LIMIT 50;

-- 5. Export Sheets (curated)
COPY (SELECT product_id, title, price, review_count, merchant_key FROM ...
      WHERE review_count >= 100)
TO 'export/top_reviewed.csv' (HEADER);
```

Nguyên tắc: filter partition key trước (`crawl_date`, bucket qua `product_id % 256`);
không `SELECT *` toàn lake khi chỉ cần 1 SP/khoảng ngày.

## 4. Cấm kỵ

| Cấm | Thay bằng |
|---|---|
| `ORDER BY` toàn corpus | Sort trong bucket (213k dòng) |
| Rewrite toàn `current/` mỗi ngày | Compact bucket có delta (đọc manifest) |
| Đọc `lake/products/*` không filter ngày | Filter `crawl_date >= ...` |
| Dedup `current/` lúc query | Tin writer + DQ R15 kiểm tra |

## 5. Retention vật lý

- `lake/`: theo chính sách backup + reference counting (BACKUP_RESTORE_DESIGN).
- `current/`: luôn giữ đủ 256 buckets (serving). Không archive theo tháng.
