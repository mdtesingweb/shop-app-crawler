# Access Policy & Risks — Shop App Crawler

**Phiên bản:** 1.0 | **Ngày:** 2026-10-15 | **Trạng thái:** THAM KHẢO

Tài liệu này tách riêng vấn đề chính sách truy cập và pháp lý khỏi thiết kế kỹ thuật,
theo yêu cầu: báo cáo database design tập trung vào tính đúng đắn kỹ thuật.

## 1. Trạng thái pháp lý (đã kiểm chứng văn bản)

- **Shopify Terms of Service §1.9** (bản 2026-08-01): cấm truy cập/giám sát Services
  bằng "robot, spider, scraper, or other automated means" — nguyên văn đã đối chiếu.
- **§1.7**: cấm reproduce/copy/exploit khi không có express written permission.
- `robots.txt` của shop.app công bố sitemaps và không disallow các route đã quan sát,
  nhưng **robots.txt không phải là cho phép pháp lý**.
- Địa chỉ liên hệ về bot trong `robots.txt`: `bots@shopify.com`.

## 2. Chính sách dự án

- **Không bulk crawling, không bulk measurement** trước khi có (a) cho phép bằng văn bản
  từ `bots@shopify.com`, hoặc (b) tư vấn pháp lý phù hợp.
- Mọi đo đạc trong giai đoạn thiết kế giới hạn ở mức trang đơn lẻ phục vụ kiểm chứng
  kỹ thuật (đã thực hiện: ~10 page fetches), không phải thu thập hệ thống.
- Không bypass Cloudflare / cơ chế chống bot dưới mọi hình thức.

## 3. Rủi ro kỹ thuật-pháp lý còn lại

| Rủi ro | Mức | Ghi chú |
|---|---|---|
| Review text (Tier 3) bị Cloudflare challenge | Cao | Schema đã sẵn; data chưa có; không bypass |
| `bots@shopify.com` không trả lời / từ chối | Trung bình | Không có SLA trả lời; phương án dự phòng: tư vấn luật sư hoặc giới hạn ở data đã có |
| Artwork rights | Chưa giải quyết | Chỉ lưu URL ảnh; không tải/lưu/phân tích artwork khi chưa rõ quyền |
| Thay đổi chính sách chống bot của Shopify | Trung bình | DQ `inaccessible_rate` spike là tín hiệu sớm |

## 4. Liên hệ với thiết kế dữ liệu

- `fetch_status` (`HTTP_403`, `CHALLENGE`, ...) trong schema tồn tại để **ghi nhận
  thực tế truy cập**, không phải để lách luật.
- Mọi quyết định mở rộng thu thập đều phải đi qua tài liệu này trước.
