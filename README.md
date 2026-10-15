# Shop App Crawler

Data Acquisition Layer cho nghiên cứu POD trên **Shop app only** (`shop.app`).
Không bao gồm niche analysis, review mining, artwork analysis, design generation
(các engine downstream, ngoài phạm vi).

## Tài liệu

- [`docs/storage-architecture.md`](docs/storage-architecture.md) — Kiến trúc lưu trữ
  chính thức (APPROVED 2026-10-15): SQLite + Parquet/ZSTD + DuckDB trên Muse Cloud 100 GB,
  backup Google Drive 5 TB, bản đọc Google Sheets, code/tài liệu trên GitHub.
- `docs/` — mọi quyết định kỹ thuật được ghi lại tại đây.

## Trạng thái

- **Pháp lý:** Shopify ToS §1.9 cấm automated scraping theo văn bản. Chưa bulk crawl —
  chờ cho phép bằng văn bản từ `bots@shopify.com` hoặc tư vấn pháp lý.
- **Giai đoạn hiện tại:** phân tích & thiết kế. Chưa tạo database, chưa viết crawler,
  chưa thu thập dữ liệu quy mô lớn.

## Bố cục repo (dự kiến)

```
├── docs/            # quyết định kiến trúc, nghiên cứu
├── src/             # source code crawler (khi được phê duyệt triển khai)
├── schemas/         # schema.json các bảng/file
├── prompts/         # prompts cho AI classification
└── tests/           # tests
```
