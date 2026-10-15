# Kiến Trúc Lưu Trữ — Shop App Crawler

**Phiên bản:** 1.0
**Trạng thái:** ✅ APPROVED (quyết định chính thức)
**Ngày phê duyệt:** 2026-10-15
**Phạm vi:** Data Acquisition Layer cho Shop app only (`shop.app`). Không bao gồm niche analysis,
review mining, artwork analysis, design generation (downstream, ngoài phạm vi).

Tài liệu này là bản ghi quyết định kiến trúc chính thức. Mọi thay đổi phải qua phê duyệt
và ghi vào mục Revision History ở cuối.

---

## 1. Vai trò các dịch vụ

| Dịch vụ | Vai trò | Không dùng để |
|---|---|---|
| **Muse Cloud 100 GB** | Môi trường vận hành và xử lý chính | Lưu trữ dài hạn duy nhất (không có backup nội tại) |
| **SQLite + Parquet/ZSTD + DuckDB** | Hệ lưu trữ và truy vấn chính, không server | Thay thế data warehouse phân tán |
| **Google Drive 5 TB** | Backup và kho dữ liệu dài hạn: full backup SQLite, Parquet, raw datasets, history, research evidence | Truy vấn trực tiếp, thay thế database |
| **Google Sheets** | Bản dữ liệu dạng bảng để xem, lọc, kiểm tra thủ công | Backup (version history không bất biến, giới hạn 10M cells) |
| **GitHub** | Source code, prompts, tests, schema, tài liệu kỹ thuật, quyết định kiến trúc | Lưu dữ liệu (giới hạn file 100 MB) |

---

## 2. Bố cục dữ liệu trên Muse Cloud

```
~/workspace/shop-app-crawler/
├── data/
│   ├── lake/                          # Parquet, phân vùng theo ngày crawl
│   │   └── crawl_date=2026-10-15/
│   │       └── part-0000-....parquet  # file bất biến, không bao giờ sửa
│   ├── current/                       # vật lý hóa "trạng thái mới nhất", theo tháng
│   │   └── ym=2026-10/
│   │       └── bucket-000.parquet
│   ├── state/
│   │   └── crawl_state.db             # SQLite WAL: URL inventory, queue, checkpoint, dedup
│   ├── manifests/
│   │   └── manifest-2026-10-15T0000.json
│   ├── tmp/                           # staging, spill DuckDB
│   └── backup-staging/                # bản backup local trước khi lên Drive
├── docs/                              # tài liệu (thư mục này)
└── README.md
```

Quy tắc sắt:
- File Parquet trong `lake/` là **bất biến (immutable)** — chỉ thêm file mới, không sửa/xóa file cũ,
  trừ khi retention policy ở mục 7 cho phép và không còn snapshot nào tham chiếu.
- Mọi thư mục dữ liệu đều có `README.md` + `schema.json` tự mô tả để agent/tác nhân khác
  đọc được mà không cần hỏi.

---

## 3. Bốn loại bản ghi (không trùng lặp)

| Loại | Nội dung | Cách lưu |
|---|---|---|
| **Raw snapshots (delta)** | Mỗi đợt crawl chỉ ghi file Parquet delta: sản phẩm mới, sản phẩm đổi field, tombstone (SP biến mất) | File bất biến trong `lake/crawl_date=.../` |
| **Changed records** | Dòng `(product_id, changed_fields, observed_at)`, ~40 B/dòng nén | Nằm trong file delta |
| **Current records** | View logic "trạng thái mới nhất mỗi product_id" | Vật lý hóa theo tháng trong `current/`, hoặc query-time bằng `ROW_NUMBER()` |
| **Crawl states** | URL inventory, hàng đợi, checkpoint, lỗi, dedup | SQLite, UPDATE tại chỗ qua WAL, kích thước ổn định theo corpus |

**Không bao giờ** snapshot toàn bộ corpus trong mỗi lần crawl. Compaction chỉ gộp partition
tháng hiện tại + delta, bucket theo `hash(product_id) % 256` để dedup song song —
không full-rewrite toàn corpus (đã chứng minh trên máy 2 CPU / 7,7 GB RAM là không khả thi).

---

## 4. Đồng bộ tăng dần Muse Cloud → Google Drive

- **Manifest-driven:** `manifest.json` local ghi `{đường dẫn: {md5, sha256, size, rows, drive_id}}`.
  Mỗi lần sync diff manifest với listing trên Drive, chỉ upload file mới/đổi.
- **Chống duplicate:** định danh nội dung bằng hash — chạy lại idempotent, không tạo bản trùng.
- **Checkpoint/resume:** checkpoint ghi sau mỗi file upload xong; đứt giữa chừng chạy lại
  tiếp tục từ diff, không upload lại từ đầu.
- **Thứ tự:** upload data trước, **manifest cuối cùng**. Restore luôn đọc manifest mới nhất —
  manifest là tuyên bố "snapshot này đầy đủ".
- **Versioning:** prefix theo ngày (`/ShopAppBackup/lake/2026-10-15/`), không ghi đè.
- **Giới hạn đã xác minh:** Drive cho file tối đa 5 TB, 750 GB/ngày (volume ta chỉ ở mức MB/ngày),
  resumable upload + exponential backoff khi lỗi; tốc độ upload đo thực tế ~2,2 MB/s
  (seed đầy đủ ~30 GB chạy qua đêm, có checkpoint từng file).

---

## 5. Backup integrity (điều chỉnh bắt buộc #1)

> **Quy định:** `md5Checksum` do Google Drive trả về **phải được so sánh với MD5 tính từ
> file local**, không phải SHA-256.

Lý do: Drive tính MD5 nội tại cho mọi file không phải Google-native. So MD5-với-MD5 cho
phép xác minh tính toàn vẹn đường truyền ngay tại thời điểm upload, không có nguy cơ
lệch do khác thuật toán.

- **Tại thời điểm upload:** tính MD5 local → upload → đọc `md5Checksum` Drive trả về →
  so khớp. Không khớp = upload lại, không ghi vào manifest.
- **SHA-256** tiếp tục được lưu trong manifest cho mỗi file và dùng để **kiểm chứng sau restore**
  (tải về → tính SHA-256 → so với manifest). SHA-256 mạnh hơn cho lưu trữ dài hạn;
  MD5 chỉ dùng cho vòng upload/Drive.
- Manifest mỗi file lưu cả hai: `{md5, sha256, size, rows}`.

---

## 6. Snapshot nhất quán & retention an toàn (điều chỉnh bắt buộc #2)

> **Quy định:** Mỗi manifest đại diện cho **một snapshot dữ liệu nhất quán**.
> Khi Parquet compaction thay thế file, **không được xóa bản cũ đang được các backup
> snapshot tham chiếu**.

Cơ chế:

1. **File bất biến + đặt tên theo nội dung:** file mới từ compaction có tên mới
   (chứa hash/timestamp); file cũ không bị sửa đổi.
2. **Manifest tham chiếu theo tên file chính xác:** một snapshot = tập đóng các file
   tại thời điểm manifest được chốt. Khôi phục từ manifest luôn tái tạo đúng trạng thái đó.
3. **Reference counting trước khi xóa:** một file vật lý chỉ được xóa khi **không còn
   manifest nào trong retention window tham chiếu tới nó**. Quy trình retention:
   - Liệt kê mọi manifest còn hiệu lực theo chính sách bên dưới.
   - Thu thập tập file được tham chiếu (hợp của tất cả manifest).
   - Chỉ xóa file ngoài tập này.
4. **Retention policy:**
   - Snapshot hằng ngày: giữ 7 ngày gần nhất.
   - Snapshot hằng tuần: giữ 4 tuần.
   - Snapshot hằng tháng: giữ 12 tháng.
   - Manifest của snapshot đã hết hạn được đánh dấu `expired`, nhưng file vật lý
     chỉ xóa sau bước reference counting.
5. **Compaction an toàn:** compaction ghi file mới → chốt manifest mới tham chiếu file mới →
   chạy retention (bước 3–4). Không bao giờ xóa-trước-ghi-sau.

---

## 7. Backup SQLite nhất quán

- **Không bao giờ** copy file `-wal`/`-shm` đang live.
- Quy trình: `VACUUM INTO backup-staging/crawl_state-YYYYMMDD.db`
  (tạo snapshot nhất quán, độc lập) → tính MD5 + SHA-256 → upload Drive →
  so MD5 với `md5Checksum` → ghi manifest.
- Restore: tải về → SHA-256 khớp manifest → đặt vào `state/` → mở kiểm tra
  `PRAGMA integrity_check` → sẵn sàng.

## 8. Quy trình restore & kiểm chứng

1. Đọc manifest mới nhất trên Drive.
2. Tải toàn bộ file trong manifest về thư mục trống.
3. Tính SHA-256 từng file, so với manifest — **100% phải khớp**, một file lệch là
   restore fail, không dùng một phần.
4. Đặt vào đúng bố cục mục 2; restore SQLite theo mục 7.
5. Spot-check: `SELECT COUNT(*)`, kiểm tra biên ngày, so với `rows` trong manifest.
6. Drill restore định kỳ mỗi quý vào thư mục trống (không đè dữ liệu đang chạy).

## 9. Luật xóa dữ liệu local

**Chỉ được xóa dữ liệu local sau khi đồng thời thỏa:**
1. Manifest trên Drive đã verify đầy đủ (100% checksum khớp), **và**
2. Drill restore spot-check pass trên bản backup đó.

Không có ngoại lệ. Không xóa theo cảm tính "chắc đã lên Drive".

---

## 10. Google Sheets — bản đọc curated

- Trước mắt **chỉ mirror curated data** (ví dụ top-reviewed mỗi niche), quyết định
  mirror toàn corpus sau.
- Shard **500.000 dòng/file** (12 cột ≈ 6M cells < giới hạn 10M cells/spreadsheet).
- Ghi ở chế độ **RAW** (đã phát hiện `USER_ENTERED` biến 31.5 thành "31,5" do locale Việt).
- Đọc tên tab thật từ API trước khi ghi (tab mặc định là "Trang tính1", không phải "Sheet1");
  pre-size grid trước khi ghi vì ghi vượt grid là lỗi.
- Sheets **không phải backup** và không thay thế backup Parquet.

---

## 11. Storage budget 100 GB (giả định — chưa chứng minh)

| Hạng mục | 54,5M SP (giả định) |
|---|---|
| Dữ liệu chính (SQLite + Parquet) | ~14 GB |
| SQLite WAL lúc bulk load | 2 GB |
| DuckDB spill (sort/join lớn) | 30 GB |
| Temp/staging | 5 GB |
| Backup local 1 bản | 15 GB |
| Headroom an toàn | 20 GB |
| **Tổng** | **~86 GB** |

Vừa nhưng chặt — cài báo động khi disk > 80%. Con số 14 GB và tăng trưởng ~1 GB/năm
là **giả định**, gate kiểm chứng: sau 1M dòng thật đầu tiên, đo lại B/dòng và reforecast.

---

## 12. Benchmark đã đo (dữ liệu Shop app thật, 92 tiles từ 3 merchants)

| Thành phần | Đo được |
|---|---|
| JSONL thô | 508 B/dòng |
| SQLite heap + PK (`dbstat`) | 369 B/dòng |
| Index merchant / review_count / collection | 24 / 14 / 23 B/dòng |
| Quan hệ product–collection | 21 B/edge (~2 edge/SP) |
| Parquet + ZSTD (high-cardinality, gần thực tế 54,5M) | 149 B/dòng (3,7x) |
| Chốt ước lượng trung tâm cho forecast | **~130 B/dòng** |

Môi trường đo: 2 CPU, 7,7 GB RAM (không swap), SSD ghi 793 MB/s.
Kết luận từ đo: full-rewrite 54,5M dòng mất 30–90+ phút (spill đĩa) → kiến trúc
cấm full-rewrite, chỉ compact partition tháng hiện tại.

---

## 13. Rủi ro còn lại

1. **Pháp lý (chặn):** Shopify ToS §1.9 cấm automated scraping theo văn bản.
   Không bulk crawling/đo đạc bulk trước khi có (a) cho phép bằng văn bản từ
   `bots@shopify.com`, hoặc (b) tư vấn pháp lý. Email xin phép đã soạn, chưa gửi.
2. **Review text (Tier 3):** UNKNOWN — product detail bị Cloudflare challenge;
   không bypass. Chỉ thu aggregate từ search/collection/merchant tiles.
3. **Dung lượng:** mọi forecast là giả định đến khi có 1M dòng thật.
4. **Upload Drive ~2,2 MB/s:** seed đầu chậm — chạy qua đêm, checkpoint từng file.
5. **Ảnh:** chỉ lưu URL ảnh, không tải/lưu/phân tích artwork khi chưa rõ quyền.

---

## Revision History

| Ngày | Phiên bản | Thay đổi |
|---|---|---|
| 2026-10-15 | 1.0 | APPROVED. Kiến trúc 5 dịch vụ; điều chỉnh #1 (MD5-vs-md5Checksum tại upload, SHA-256 cho post-restore); điều chỉnh #2 (manifest = snapshot nhất quán, cấm xóa file được tham chiếu, reference counting + retention). |
