# Backup & Restore Design — Shop App Crawler

**Phiên bản:** 1.1 | **Ngày:** 2026-10-15 | **Trạng thái:** DRAFT chờ duyệt

v1.1: backup manifest bao gồm `current_manifest.json` (để restore kiểm tra
tính đầy đủ của `current/`).

Tương thích `docs/storage-architecture.md` mục 4–9 (đã APPROVED):
MD5-vs-md5Checksum tại upload · SHA-256 post-restore · manifest = snapshot nhất quán ·
cấm xóa file được tham chiếu · chỉ xóa local sau khi verify + drill pass.

## 1. Snapshot nhất quán Parquet + SQLite (yêu cầu #13)

Vấn đề: backup chứa `crawl_state.db` (SQLite) và `lake/` (Parquet) **không được lệch nhau**
(db nói "đã crawl tới X" nhưng Parquet thiếu file của X).

Quy trình chốt snapshot (nguyên tử ở mức thực tế):

```
1. PAUSE compaction + ingest (cờ trong crawl_jobs: job kind='backup' status='RUNNING'
   → worker khác không ghi lake/; đơn giản, không cần distributed lock).
2. SQLite: PRAGMA wal_checkpoint(TRUNCATE) rồi VACUUM INTO backup-staging/crawl_state-<ts>.db
   → snapshot SQLite độc lập, nhất quán.
3. Đóng băng danh sách file Parquet: liệt kê lake/ + current/ tại thời điểm này.
4. Tính MD5 + SHA-256 mọi file; ghi backup manifest (mục 2).
5. Upload: data trước, manifest cuối cùng.
6. Verify: so MD5 local vs md5Checksum Drive cho 100% file.
7. RESUME compaction + ingest.
```

Cửa sổ pause chỉ vài phút (liệt kê + hash, không copy dữ liệu). Nếu crash giữa chừng:
manifest chưa chốt = snapshot chưa tồn tại → chạy lại từ đầu, idempotent.

## 2. Backup manifest

`manifest-<ts>.json` trên Drive (`/ShopAppBackup/manifests/`):

```json
{
  "snapshot_ts": "2026-10-15T00:00:00Z",
  "schema_version": "1.0",
  "sqlite": {"path": "state/crawl_state-20261015.db",
             "md5": "...", "sha256": "...", "bytes": 12345},
  "current_manifest": {"path": "current/current_manifest.json",
             "md5": "...", "sha256": "..."},
  "parquet": [
    {"path": "lake/products/crawl_date=2026-10-15/part-0000.parquet",
     "md5": "...", "sha256": "...", "bytes": 134217728, "rows": 812340}
  ],
  "prev_manifest": "manifest-20261014T000000.json"
}
```

`prev_manifest` tạo chuỗi incremental — restore full = manifest mới nhất
(truy ngược khi cần file từ snapshot cũ, vì retention giữ file được tham chiếu).

## 3. Retention an toàn (điều chỉnh bắt buộc #2)

- File Parquet bất biến, đặt tên theo nội dung — compaction không sửa file cũ.
- Xóa file vật lý **chỉ khi** không còn manifest nào trong retention window
  (daily 7 / weekly 4 / monthly 12) tham chiếu tới nó (reference counting).
- Manifest hết hạn → đánh dấu `expired`, không xóa ngay.

## 4. Restore

```
1. Tải manifest mới nhất (hoặc manifest chỉ định).
2. Tải toàn bộ file trong manifest về thư mục TRỐNG.
3. SHA-256 từng file == manifest (100% khớp, 1 file lệch = fail toàn bộ).
4. Đặt đúng bố cục; SQLite: PRAGMA integrity_check.
5. Spot-check: COUNT(*) vs manifest.rows; biên observed_at.
6. Drill định kỳ mỗi quý vào thư mục trống (không đè dữ liệu chạy).
```

Ước lượng restore 30 GB ở tốc độ đo được (~2,2 MB/s upload; download thường nhanh hơn
— **chưa đo**, gắn nhãn giả định): lên kế hoạch 2–4 giờ cho full restore ở 54,5M.

## 5. Phân tầng backup

| Tầng | Nội dung | Tần suất | Ưu tiên restore |
|---|---|---|---|
| Tier 0 | `crawl_state.db` (VACUUM INTO) + manifest | Mỗi ngày | Cao nhất |
| Tier 1 | `lake/` deltas mới (incremental) | Mỗi lần crawl xong | Cao |
| Tier 2 | `lake/` base + `sitemap_urls` | Mỗi tuần (nếu đổi) | Trung bình |
| Tier 3 | `current/` serving copy | Mỗi tuần | Thấp (tái tạo được) |

Local staging (`backup-staging/`) được dọn sau khi Drive verify xong —
không giữ 2 bản local vĩnh viễn (tiết kiệm 100 GB).

## 6. Luật xóa local (nhắc lại — không ngoại lệ)

Xóa dữ liệu local **chỉ khi**: (1) manifest Drive verify 100% checksum khớp,
**và** (2) drill restore spot-check pass trên chính snapshot đó.
