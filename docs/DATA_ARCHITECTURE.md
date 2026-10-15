# Data Architecture — Shop App Crawler

**Phiên bản:** 1.1 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt
**Phạm vi:** Data Acquisition Layer, Shop app only. Chưa viết crawler, chưa tạo database,
chưa thu thập bulk.

v1.1: TIMESTAMP mọi nơi · tách fetch/review status · priority scheduling (design) ·
review identity nhiều tầng · `current/` đúng 1 dòng/SP. Chi tiết thay đổi:
`SCHEMA_EVOLUTION.md` mục 6.

Mọi trường "đã kiểm chứng" dưới đây dựa trên dữ liệu Shop app đo thực tế.
Trường "giả định" được gắn nhãn rõ ràng. Vấn đề chính sách truy cập & pháp lý:
tài liệu riêng `ACCESS_POLICY_AND_RISKS.md`.

---

## 1. Nguyên tắc thiết kế

1. **Mỗi byte có chủ.** Không nhân bản vô ích: mỗi sự thật chỉ có một *source of truth*;
   bản sao phục vụ truy vấn (serving copy) phải được gắn nhãn "tái tạo được" và có mức
   ưu tiên backup thấp hơn.
2. **Append-only cho lịch sử, mutable có kiểm soát cho vận hành.** Lịch sử trong Parquet
   bất biến; trạng thái vận hành (queue, aggregates) trong SQLite WAL.
3. **Khóa tự nhiên từ Shop app.** `product_id` số từ URL, `merchant_key` từ `/m/<token>`,
   `collection_key = <merchant_key>/<collection_id>`. Không phát minh ID代理.
4. **Provenance là công dân hạng nhất** (mục 5).
5. **Thiết kế cho máy yếu:** 2 CPU, 7,7 GB RAM (không swap), 100 GB SSD.
   Cấm full-corpus sort/rewrite (xem `PARTITION_AND_COMPACTION.md`).
6. **Đơn giản > thông minh.** Ưu tiên schema ít bảng, ít join, dễ rebuild.

## 2. Danh mục thực thể

| # | Thực thể | Mô tả | Store | Tính chất |
|---|---|---|---|---|
| 1 | Sitemap URLs | Vũ trụ discovery: 54,5M product + 1,47M merchant + 524k collection URLs | Parquet | Bất biến, ghi 1 lần |
| 2 | Merchants | 1,47M merchants từ sitemap storefronts | SQLite | Ít đổi, upsert |
| 3 | Collections | 524k collections, join với merchants qua `/m/<store>` (đã kiểm chứng) | SQLite | Ít đổi, upsert |
| 4 | Products | Bản ghi sản phẩm: title, price, image URL, rating/review count (từ tiles) | Parquet | Append-only snapshots + serving copy |
| 5 | Product Images | URL ảnh + alt-text (đã kiểm chứng alt dài 20–200 ký tự). **Chỉ URL, không binary** | Parquet | Append-only |
| 6 | Reviews | (a) Aggregate `review_count`/`rating` — đã có từ tiles; (b) review text — **schema sẵn, chưa có data** (Tier 3 bị chặn) | SQLite (a) + Parquet (b) | (a) mutable, (b) append-only |
| 7 | Product–Collection | Quan hệ n–n (1 SP trong nhiều collections — đã kiểm chứng) | Parquet | Append-only theo đợt quan sát |
| 8 | Product–Merchant | Quan hệ quan sát được (sitemap products **không** có merchant key — đã kiểm chứng; link này chỉ có khi thấy SP trên trang merchant/collection) | Parquet | Append-only observations |
| 9 | Crawl Jobs | Đợt crawl: loại, mục tiêu, trạng thái, thống kê | SQLite | Mutable, nhỏ |
| 10 | Crawl State (queue) | Hàng đợi URL mục tiêu, lease, retry — **chỉ giữ cửa sổ đang chạy** (~1M), refill từ sitemap | SQLite | Mutable, prunable |
| 11 | Errors | Lỗi crawl: aggregate đầy đủ + sample chi tiết | SQLite | Append-only (sampled) |
| 12 | Observations | Provenance mỗi lần quan sát (gắn ở row-level, mục 5) | Cột trên mọi bảng | Bất biến theo dòng |
| 13 | Change History | Field-level diffs append-only | Parquet | Bất biến, phân vùng theo tháng |

## 3. Phân chia SQLite / Parquet / DuckDB

```
┌─────────────────────────────────────────────────────────────┐
│ SQLite (crawl_state.db, WAL) — VẬN HÀNH, mutable             │
│  merchants, collections, product_review_state,              │
│  crawl_jobs, crawl_targets (queue window), crawl_errors,     │
│  dq_violations, sheets_export_log                           │
│  → point lookup nhanh, UPDATE tại chỗ, ACID cho checkpoint  │
├─────────────────────────────────────────────────────────────┤
│ Parquet (lake/, current/) — LỊCH SỬ + SERVING, bất biến      │
│  sitemap_urls, products (base+deltas), product_collections,  │
│  product_merchants, product_images, reviews (future),       │
│  field_changes                                              │
│  → nén ZSTD (~3,7x đo được), scan phân tích nhanh           │
├─────────────────────────────────────────────────────────────┤
│ DuckDB — ENGINE TRUY VẤN duy nhất (không server)            │
│  ATTACH sqlite + read_parquet(); join 3 nguồn trong 1 query  │
│  → mọi phân tích, export, DQ đều qua DuckDB                 │
└─────────────────────────────────────────────────────────────┘
```

**Bản đồ "không nhân bản":**

| Sự thật | Source of truth | Bản sao phục vụ | Ghi chú |
|---|---|---|---|
| Trạng thái SP mới nhất | `lake/` deltas (replay) | `current/` (vật lý hóa, **đúng 1 dòng/SP**) | `current/` tái tạo được → backup ưu tiên thấp |
| Aggregate review hiện tại | `product_review_state` (SQLite) | — | UPDATE tại chỗ; **fetch fail không đụng data columns** (v1.1) |
| Quan hệ P–C–M | `product_collections`, `product_merchants` (Parquet) | — | Không mảng lồng trong bảng products |
| Nội dung tile tại thời điểm T | `lake/products` snapshot rows | — | `review_count` trong snapshot = quan sát tại T; aggregate mới nhất ở SQLite |
| URL discovery | `sitemap_urls` (Parquet) | — | `crawl_targets` KHÔNG lưu URL, resolve lúc dispatch (tiết kiệm ~4 GB) |

## 4. Luồng dữ liệu tổng thể

```
sitemap_urls ──► crawl_jobs ──► crawl_targets (queue window, lease/retry)
      │                │
      │                ▼
      │         fetch tiles ──► observations ──┬──► lake/products (delta)
      │                                       ├──► lake/product_collections
      │                                       ├──► lake/product_merchants
      │                                       ├──► lake/product_images
      │                                       ├──► field_changes (diff vs current)
      │                                       └──► product_review_state (upsert SQLite)
      ▼
compaction (per-bucket, atomic replace) ──► current/ ──► DuckDB queries / Sheets export (curated)
      │
      ▼
backup manifest ──► Google Drive (MD5 verify tại upload, SHA-256 post-restore)
```

## 5. Provenance (bắt buộc mọi dòng dữ liệu)

Mỗi bảng mang 4 cột provenance ở **row-level** (trade-off có chủ ý: thay vì cột
provenance cho từng field — quá đắt ở 54,5M dòng — ta lưu provenance theo dòng
+ lịch sử diff theo field trong `field_changes`):

| Cột | Kiểu | Ý nghĩa |
|---|---|---|
| `source_surface` | TEXT | `sitemap` \| `collection_tile` \| `merchant_tile` \| `search_tile` \| `product_page` |
| `observed_at` | TIMESTAMP | UTC, microsecond khi có — **phân biệt nhiều quan sát cùng ngày** (v1.1) |
| `collector_version` | TEXT | Phiên bản crawler (vd `crawler-0.3.0`) |
| `parser_version` | TEXT | Phiên bản parser tile (vd `tile-parser-0.2.1`) |

Suy luận (inference) mang thêm `confidence REAL`:
- Vd: "tile không hiện count ⟺ SP chưa có review" là **suy luận** (`confidence=0.9`,
  đã kiểm chứng trên 3 merchants nhưng chưa chứng minh toàn site), không phải sự thật đo được.
- `review_status='NO_REVIEWS'` từ suy luận này phải đi kèm confidence; downstream
  được phép lọc `confidence >= 0.95` nếu cần chắc chắn.

## 6. Ranh giới cho engine tương lai (interface contracts, CHƯA triển khai)

| Engine | Đọc từ (hợp đồng đầu vào) | Không được chạm |
|---|---|---|
| Niche Research | `current/` products + `product_collections` + `collections` + `product_review_state` | Bảng nội bộ của engine khác |
| Review Intelligence | `product_review_state` + `lake/reviews/` (khi mở) + `field_changes` (review velocity) | Raw HTML, session crawl |
| Design Intelligence | `product_images` (URL) + `products.title` | Binary ảnh (chưa có quyền) |

Mỗi engine sau này sở hữu namespace riêng (`niche_*`, `reviewi_*`, `design_*`) —
cấm viết vào bảng của Data Acquisition Layer.

## Phụ lục A — Ước lượng dung lượng 1M / 10M / 54,5M (tháng 12)

**[M]** = đo được từ benchmark · **[A]** = giả định. Đối chiếu với ước lượng 14 GB cũ:
14 GB chỉ tính *core corpus* (metadata+URL+edges+state); bảng dưới là *toàn bộ thiết kế
vận hành* (thêm images, queue, jobs, deltas, serving copy) nên lớn hơn — vẫn vừa 100 GB.

### SQLite (vận hành)

| Bảng |/dòng | 1M SP | 10M SP | 54,5M SP |
|---|---|---|---|---|
| merchants (1,47M cố định) | 150 B **[A]** | 0,22 GB | 0,22 GB | 0,22 GB |
| collections (524k cố định) | 170 B **[A]** | 0,09 GB | 0,09 GB | 0,09 GB |
| product_review_state | 120 B **[A]** | 0,12 GB | 1,2 GB | 6,5 GB |
| crawl_targets (window 1M) | 100 B **[A]** | 0,1 GB | 0,1 GB | 0,1 GB |
| jobs/errors/dq | — **[A]** | 0,05 GB | 0,1 GB | 0,2 GB |
| **Tổng SQLite** | | **~0,6 GB** | **~1,7 GB** | **~7,1 GB** |

### Parquet (lịch sử + serving)

| Dataset | /dòng | 1M SP | 10M SP | 54,5M SP |
|---|---|---|---|---|
| sitemap_urls (56,5M cố định) | ~10 B **[A]** | 0,6 GB | 0,6 GB | 0,6 GB |
| products base | 149 B **[M]** | 0,15 GB | 1,5 GB | 8,1 GB |
| current/ (serving, tái tạo được) | 149 B **[M]** | 0,15 GB | 1,5 GB | 8,1 GB |
| product_collections (~2 edges/SP) | 12 B/edge **[M]** | 0,02 GB | 0,24 GB | 1,3 GB |
| product_merchants | 30 B **[A]** | 0,03 GB | 0,3 GB | 1,6 GB |
| product_images (~1 ảnh/SP) | 50 B **[A]** | 0,05 GB | 0,5 GB | 2,7 GB |
| field_changes (1 năm) | — **[A]** | 0,05 GB | 0,5 GB | 1,6 GB |
| **Tổng Parquet** | | **~1,1 GB** | **~5,1 GB** | **~24 GB** |

### Tổng + reviews (kịch bản)

| | 1M SP | 10M SP | 54,5M SP |
|---|---|---|---|
| Tổng SQLite + Parquet | **~1,7 GB** | **~6,8 GB** | **~31 GB** |
| + review text (5% SP × 15 reviews) **[A]** | +0,06 GB | +0,6 GB | +3 GB |
| + review text (20% SP × 30 reviews) **[A]** | +0,5 GB | +5 GB | +25 GB |

Ngân sách 100 GB ở 54,5M: 31 (data) + 2 (WAL) + 15 (spill cap) + 3 (temp) + 20
(headroom) ≈ 71 GB — vừa; local backup staging chỉ tồn tại trong cửa sổ backup
(dọn sau khi Drive verify). Đòn bẩy lớn nhất nếu chật: `current/` (8 GB, tái tạo được),
`product_images` khi product page mở (giả định số ảnh/SP).

---

## 7. Trade-off lớn đã chọn (và cái giá)

| Quyết định | Được | Mất |
|---|---|---|
| Khóa tự nhiên TEXT (`merchant_key`, `collection_key`) thay vì surrogate INT | Join trực tiếp SQLite↔Parquet↔DuckDB, không cần bảng map ID | Tốn ~10–20 B/dòng; Parquet dictionary encoding bù lại phần lớn |
| `product_review_state` riêng trong SQLite thay vì UPDATE Parquet | UPDATE rẻ, checkpoint ACID | Hai nơi chứa review_count (snapshot vs current) — phải document rõ ngữ nghĩa |
| `current/` vật lý hóa (duplicate logic) | Query nhanh trên máy yếu, không dedup mỗi lần đọc | ~8 GB thêm ở 54,5M; nhưng tái tạo được → backup ưu tiên thấp |
| `field_changes.old/new` dạng TEXT | Schema ổn định, không migration khi thêm field | Mất type-safety; parse lại khi phân tích |
| Queue chỉ giữ window ~1M (không 54,5M) | SQLite nhẹ (~100 MB), refill từ sitemap | Worker phải refill; giám sát "đói queue" |
| Errors sampled (không raw toàn bộ) | Tiết kiệm ~10 GB | Mất chi tiết lỗi hiếm — chấp nhận được |

Chi tiết: `DATABASE_SCHEMA.md`, `ENTITY_RELATIONSHIP.md`, `SQLITE_SCHEMA.sql`,
`PARQUET_SCHEMAS.md`, `DATA_DICTIONARY.md`.
