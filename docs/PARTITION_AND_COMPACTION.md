# Partition, Bucketing, Compaction & DuckDB Patterns

**Phiên bản:** 1.2 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt (vòng cuối)

Máy mục tiêu: 2 CPU, 7,7 GB RAM (**không swap**), SSD 100 GB.
v1.2: `current/` publication nguyên tử qua **generation manifest** — crash giữa
compaction không bao giờ lộ snapshot lẫn lộn nhiều generation.

---

## 1. Partitioning

```
lake/
  sitemap_urls/url_type=*/part-*.parquet
  products/crawl_date=YYYY-MM-DD/part-<job_id>-<batch>.parquet  # tên xác định → idempotent replay
  product_collections/crawl_date=*/part-*.parquet
  product_images/crawl_date=*/part-*.parquet
  reviews/crawl_date=*/part-*.parquet              # future
  field_changes/ym=YYYY-MM/part-*.parquet
  product_merchants/merchant_shard=*/part-*.parquet

ingest_staging/<job_id>/batch-<n>.jsonl           # staging thô, fsync trước Parquet

current/
  generations/gen_<NNN>/bucket-000.parquet … bucket-255.parquet
  manifests/manifest_gen_<NNN>.json               # đủ 256 buckets/generation
  current_latest.json                             # {"generation":"gen_0007"} — con trỏ nguyên tử
```

- `bucket = hash(product_id) % 256` (FNV-1a; đổi hàm = migration).
- Mỗi bucket ở 54,5M ≈ 213k dòng — vừa RAM.
- File target 128–256 MB.

## 2. Compaction — publication nguyên tử theo generation (v1.2)

Mỗi lần compaction tạo một **generation** mới:

```
gen = next_generation()                      # gen_0008
changed = buckets có delta mới (so current_manifest vs lake)

cho mỗi bucket b trong changed (độc lập, idempotent):
    đọc:  resolve(gen hiện tại, b) → file bucket b của generation đang live
        + lake/products/crawl_date=<k ngày qua>/part-*.parquet
          với predicate pushdown product_id % 256 == b
    dedup: ROW_NUMBER() OVER (PARTITION BY product_id
           ORDER BY observed_at, observation_id) = 1
    ghi:  current/generations/gen_0008/bucket-b.parquet

ghi manifests/manifest_gen_0008.json:
    cho mỗi bucket 0..255:
      nếu b trong changed → trỏ file mới gen_0008
      nếu không           → giữ nguyên file từ manifest generation cũ (KHÔNG copy)

PUBLISH: atomic rename current_latest.json → {"generation": "gen_0008"}
dọn: staging gen_0008 (giờ là live, không phải staging nữa);
     orphan generations (không được manifest nào trỏ, >24h) → xóa
```

**Tính chất:**
- Crash ở bất kỳ bước nào trước PUBLISH: `current_latest.json` chưa đổi →
  reader vẫn thấy generation cũ **nhất quán 100%**. Không tồn tại snapshot
  lẫn lộn bucket cũ + bucket mới.
- Crash sau PUBLISH: generation mới đã live đầy đủ.
- Chạy lại compaction: idempotent — bucket đã ghi ở gen_0008 thì skip.
- Mỗi bucket vài giây (đo 194k dòng/s in-RAM); toàn bộ 256 buckets ~5–20 phút
  tùy số bucket đổi.

**Bất biến 1-dòng-1-SP:** trong một generation manifest, mỗi product_id xuất hiện
đúng một lần (writer đảm bảo; DQ R15 kiểm tra). Query **không dedup lại**.

## 3. DuckDB query patterns

```sql
-- 0. Resolve generation hiện tại (helper — mọi query current/ bắt đầu ở đây)
--    Đọc current_latest.json → manifest → danh sách 256 files.
--    Ví dụ với Python:
--    files = resolve_current('data/current')  # -> list[str]

-- 1. Point lookup — không dedup
SELECT * FROM read_parquet(['data/current/generations/gen_0007/bucket-*.parquet'])
WHERE product_id = 10269120594195;

-- 2. Lịch sử giá/review 1 SP (intraday đầy đủ, thứ tự xác định)
SELECT observed_at, observation_id, price, review_count
FROM read_parquet('data/lake/products/crawl_date=*/part-*.parquet', hive_partitioning=true)
WHERE product_id = 10269120594195
ORDER BY observed_at, observation_id;

-- 3. Aggregate review theo merchant (SQLite state — nhanh)
SELECT m.merchant_key, COUNT(*) n,
       SUM(CASE WHEN r.review_status='HAS_REVIEWS' THEN 1 ELSE 0 END) n_reviewed
FROM s.product_review_state r
JOIN read_parquet('data/lake/product_merchants/*/*.parquet') pm
  ON pm.product_id = r.product_id
JOIN s.merchants m ON m.merchant_key = pm.merchant_key
GROUP BY 1;

-- 4. Top collections theo reward (priority scheduling)
SELECT c.collection_key, c.priority_score, SUM(st.reward_r10) r10
FROM s.collections c
JOIN s.collection_crawl_stats st ON st.collection_key = c.collection_key
GROUP BY 1, 2 ORDER BY r10 DESC LIMIT 50;

-- 5. Export Sheets (curated)
COPY (SELECT product_id, title, price, review_count FROM ... WHERE review_count >= 100)
TO 'export/top_reviewed.csv' (HEADER);
```

Nguyên tắc: filter partition key trước; không `SELECT *` toàn lake khi chỉ cần
1 SP/khoảng ngày; current/ đọc qua manifest (không glob mù qua generations cũ).

## 4. Cấm kỵ

| Cấm | Thay bằng |
|---|---|
| `ORDER BY` toàn corpus | Sort trong bucket |
| Ghi đè trực tiếp file bucket live | Ghi generation staging + atomic publish |
| Reader glob `current/**` | Resolve qua `current_latest.json` → manifest |
| Đọc `lake/products/*` không filter ngày | Filter `crawl_date >= ...` |

## 5. Retention vật lý

- `lake/`: theo chính sách backup + reference counting.
- `current/generations/`: chỉ giữ generations được manifest trỏ tới + 1 generation
  staging đang build; orphan >24h → xóa.
