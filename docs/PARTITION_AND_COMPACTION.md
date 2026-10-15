# Partition, Bucketing, Compaction & DuckDB Patterns

**Phiên bản:** 1.0 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt

Máy mục tiêu: 2 CPU, 7,7 GB RAM (**không swap**), SSD 100 GB (ghi 793 MB/s đo được).
Kết luận đo được: full-corpus dedup+sort+rewrite 54,5M dòng mất **30–90+ phút**
(spill đĩa, OOM risk) → **thiết kế này cấm full-rewrite**.

---

## 1. Partitioning

```
lake/
  sitemap_urls/url_type=*/part-*.parquet        # 3 partitions, ghi 1 lần
  products/crawl_date=YYYY-MM-DD/part-*.parquet # 1..n files/ngày, bất biến
  product_collections/crawl_date=*/part-*.parquet
  product_images/crawl_date=*/part-*.parquet
  reviews/crawl_date=*/part-*.parquet           # future
  field_changes/ym=YYYY-MM/part-*.parquet
  product_merchants/merchant_shard=*/part-*.parquet  # gộp theo batch merchant, không theo ngày

current/
  ym=YYYY-MM/bucket-000.parquet … bucket-255.parquet
```

- `bucket = hash(product_id) % 256` (hash ổn định, vd FNV-1a — ghi trong SCHEMA_EVOLUTION;
  đổi hàm hash = migration).
- Mỗi bucket ở 54,5M ≈ 213k dòng — vừa RAM để dedup/sort cục bộ.
- File target 128–256 MB (vừa upload Drive ~2,2 MB/s, vừa đọc DuckDB).

## 2. Compaction (chỉ partition nóng)

**Không bao giờ** đọc toàn `lake/` trong một job. Compaction chạy theo
`(ym hiện tại, bucket)`:

```
cho mỗi bucket b trong 0..255:
    đọc:  current/ym=<tháng này>/bucket-b.parquet   (nếu có)
        + lake/products/crawl_date=<30 ngày qua>/part-*.parquet  (filter product_id % 256 == b
            bằng predicate pushdown — đọc metadata trước, skip file không liên quan)
    dedup: ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY observed_at DESC) = 1
    ghi:  current/ym=<tháng này>/bucket-b.parquet (ghi file mới, đổi tên nguyên tử)
```

- Mỗi bucket xử lý độc lập → 256 job nhỏ, crash giữa chừng chỉ mất 1 bucket,
  chạy lại idempotent.
- Tháng cũ: **đóng băng** (không compact lại). Query đọc nhiều tháng qua union.
- `product_merchants`: compact theo merchant batch khi observations mới về.

Chi phí ước lượng: 1 bucket ≈ 213k + delta dòng → vài giây (đo được 194k dòng/s
in-RAM). Toàn bộ 256 buckets: chạy tuần tự ~10–20 phút, song song 2 CPU ~5–10 phút.
Không spill.

## 3. DuckDB query patterns (chuẩn cho mọi phân tích)

```sql
-- 0. Attach 2 nguồn (1 lần/session)
ATTACH 'data/state/crawl_state.db' AS s;  -- SQLite
-- Parquet đọc trực tiếp, không cần attach

-- 1. Point lookup: SP mới nhất
SELECT * FROM read_parquet('data/current/ym=*/bucket-*.parquet',
                           hive_partitioning=true)
WHERE product_id = 10269120594195;

-- 2. Aggregate review theo merchant (niche analysis)
SELECT m.merchant_key, COUNT(*) n_products,
       SUM(CASE WHEN r.review_status='HAS_REVIEWS' THEN 1 ELSE 0 END) n_reviewed,
       SUM(r.review_count) total_reviews
FROM s.product_review_state r
JOIN read_parquet('data/lake/product_merchants/*/*.parquet') pm
  ON pm.product_id = r.product_id
JOIN s.merchants m ON m.merchant_key = pm.merchant_key
GROUP BY 1 ORDER BY total_reviews DESC;

-- 3. Quan hệ P–C–M đầy đủ (giữ mọi collection, kể cả generic)
SELECT p.product_id, p.title, p.price, pc.collection_key, c.slug, m.display_name
FROM read_parquet('data/current/ym=*/bucket-*.parquet') p
JOIN read_parquet('data/lake/product_collections/crawl_date=*/part-*.parquet') pc
  ON pc.product_id = p.product_id
JOIN s.collections c ON c.collection_key = pc.collection_key
JOIN s.merchants m  ON m.merchant_key = c.merchant_key
WHERE c.intent_tier = 'garment';

-- 4. Change detection (price/review velocity) — không scan toàn lake
SELECT entity_key, field_name, old_value, new_value, observed_at
FROM read_parquet('data/lake/field_changes/ym=2026-10/*.parquet')
WHERE entity_type='product' AND field_name IN ('price','review_count');

-- 5. Export Sheets (curated): DuckDB COPY ra CSV rồi upload theo batch
COPY (SELECT product_id, title, price, review_count, merchant_key
      FROM ... WHERE review_count > 100)
TO 'export/top_reviewed.csv' (HEADER);
```

Nguyên tắc: **filter trên partition key trước** (`ym`, `crawl_date`, `bucket`
qua `product_id % 256`), không `SELECT *` toàn lake khi chỉ cần 1 tháng.

## 4. Cấm kỵ (anti-patterns)

| Cấm | Vì sao | Thay bằng |
|---|---|---|
| `ORDER BY` toàn corpus 54,5M | Spill hàng chục GB, OOM risk | Sort trong bucket (213k dòng) |
| Rewrite toàn `current/` mỗi ngày | 30–90+ phút, chặn mọi query | Compact bucket của tháng hiện tại |
| Đọc `lake/products/*` không filter ngày | Scan 8 GB+ mỗi query | Filter `crawl_date >= ...` |
| Join Parquet–SQLite không filter | DuckDB kéo toàn bảng SQLite vào RAM | Filter selective trước, hoặc join theo batch key |
| File Parquet < 8 MB | Quá nhiều file nhỏ → metadata overhead, Drive sync chậm | Gộp đủ 128 MB mới chốt file |

## 5. Retention vật lý

- `lake/`: giữ theo chính sách backup (daily 7 / weekly 4 / monthly 12) + reference
  counting trước xóa (xem BACKUP_RESTORE_DESIGN).
- `current/ym` cũ hơn 3 tháng: giữ (rẻ, ~8 GB/tháng ở full scale — **giả định**),
  review lại khi disk > 80%.
