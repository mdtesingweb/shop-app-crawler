# Entity Relationship — Shop App Crawler

**Phiên bản:** 1.0 | **Ngày:** 2026-10-15

Ký hiệu: `PK` primary key · `FK` foreign key · `UQ` unique · `*` NOT NULL.

## ERD (SQLite — vận hành)

```
┌─────────────────────┐         ┌──────────────────────┐
│ merchants           │         │ collections          │
│─────────────────────│         │──────────────────────│
│ PK* merchant_key    │──┐   ┌──│ PK* collection_key   │
│    slug*            │  │   │  │ FK* merchant_key     │
│    display_name     │  │   │  │    collection_id*    │
│    shop_url*        │  │   │  │    slug*             │
│    myshopify_domain │UQ│   │  │    title             │
│    apparel_prior*   │  │   │  │    intent_tier       │
│    first_seen*      │  │   │  │    product_count_est │
│    last_seen*       │  │   │  │    first_seen*       │
└─────────────────────┘  │   │  │    last_seen*        │
                         │   │  └──────────────────────┘
                         │   │
┌─────────────────────┐  │   │  ┌──────────────────────┐
│ product_merchants   │  │   │  │ product_collections  │
│ (Parquet, obs.)     │  │   │  │ (Parquet, n–n)       │
│─────────────────────│  │   │  │──────────────────────│
│    product_id*      │──┼───┼──│    product_id*       │
│ FK* merchant_key    │──┘   └──│ FK* collection_key   │
│    first_observed*  │         │    position          │
│    last_observed*   │         │    observed_at*      │
│    evidence*        │         └──────────────────────┘
└─────────────────────┘                   │
                                          │
┌─────────────────────┐                   │
│ products (Parquet)  │◄──────────────────┘
│─────────────────────│
│ PK* product_id      │
│    url*             │
│    title*           │
│    price*           │
│    image_url*       │
│    review_count     │
└────────┬────────────┘
         │ 1
         ├───1 product_review_state (SQLite, mutable aggregate)
         │   │ PK* product_id │ review_count │ rating_avg │ review_status* │ confidence* │
         │
         ├───n product_images (Parquet) — URL only, no binaries
         │   │ (product_id*, image_url*)UQ │ image_alt │ position* │
         │
         └───n reviews (Parquet, FUTURE — schema sẵn, chưa data)
             │ review_id*PK │ rating │ body │ author │ verified_purchase │

┌─────────────────────┐         ┌──────────────────────┐
│ crawl_jobs          │         │ crawl_targets        │
│─────────────────────│         │──────────────────────│
│ PK* job_id          │──┐   ┌──│ PK* target_key       │
│    kind*            │  │   │  │    target_type*      │
│    target_desc*     │  │   │  │    status* (indexed) │
│    status*          │  │   │  │    attempts*         │
│    stats_json       │  │   │  │    next_retry_at*    │
└─────────────────────┘  │   │  │    lease_until       │
                         │   │  └──────────────────────┘
                         │   │
                         │   │  ┌──────────────────────┐
                         └──┼──│ crawl_errors         │
                            │  │ PK* error_id │ target_key* │ http_status │
                            │  └──────────────────────┘
                            │
┌─────────────────────┐      │  ┌──────────────────────┐
│ field_changes       │      │  │ dq_violations        │
│ (Parquet, history)  │      │  │ PK* violation_id │ rule_id* │
│ entity_type*        │      │  └──────────────────────┘
│ entity_key*         │
│ field_name*         │◄─────┘  (ghi nhận thay đổi, không FK cứng —
│ old_value           │   Parquet không enforce FK; DQ kiểm tra)
│ new_value           │
└─────────────────────┘
```

## Quan hệ nhiều–nhiều Product–Collection–Merchant

Đây là quan hệ trung tâm của hệ thống, đã kiểm chứng thực tế:

- **Một sản phẩm trong nhiều collections:** đã quan sát (vd SP thuộc cả
  `graphic-tees` lẫn `new-arrivals`). → `product_collections` giữ **toàn bộ**,
  không lọc lúc crawl.
- **Collections thuộc merchant:** join trực tiếp qua `/m/<store>` trong URL
  collection (đã kiểm chứng) → FK `collections.merchant_key`.
- **Products → merchants:** sitemap products **không** chứa merchant key
  (đã kiểm chứng) → quan hệ này là **observation** (`product_merchants`,
  có `evidence` + `first/last_observed_at`), không phải FK cứng.
  Một SP có thể có nhiều observations (hiếm); view current chọn mới nhất.

```
Ví dụ cụ thể (đã kiểm chứng):
  merchant 'dogecore'
    └── collection 'dogecore/166998114364' (graphic-tees)
          ├── product 10269120594195 ("how to live t-shirt", (14), $31.50)
          ├── product 10209753989395 ("please consult the horses", (18), $30.00)
          └── ... (62 products, infinite scroll)
```

## Review lifecycle (trạng thái)

```
NOT_YET_FETCHED ──quan sát tile──► HAS_REVIEWS (có count) / NO_REVIEWS (không count, conf 0.9)
       │                                    │
       │──403/challenge─────────────────────► INACCESSIBLE ──retry──► lại vòng quan sát
       │──404───────────────────────────────► MISSING (terminal)
```

`rating_avg` luôn NULL cho đến khi product page mở được (tiles không hiện sao —
đã kiểm chứng). Schema `reviews` chi tiết đã sẵn cho Tier 3.

## Ràng buộc toàn vẹn

| Ràng buộc | Thực thi ở | Ghi chú |
|---|---|---|
| PK/FK/UNIQUE trong SQLite | SQLite (DDL) | Enforce thật |
| FK logic trong Parquet | **Không enforce** — kiểm tra bằng DQ job (orphan detection) | Parquet không có constraint; trade-off có chủ ý |
| `review_count >= 0` | DQ rule R3 | Tiles đã chuẩn hóa `2.7K`→2700 lúc parse |
| `price > 0` | DQ rule R4 | |
| URL đúng format `shop.app/products/<id>/` | DQ rule R5 | |
| Không trùng `(product_id, image_url)` | Dedup lúc ingest | |
