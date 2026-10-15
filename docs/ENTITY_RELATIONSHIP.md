# Entity Relationship — Shop App Crawler

**Phiên bản:** 1.1 | **Ngày:** 2026-10-15

Ký hiệu: `PK` primary key · `FK` foreign key · `UQ` unique · `*` NOT NULL.
v1.1: tách fetch_status/review_status · thêm collection_crawl_stats, crawl_policy ·
TIMESTAMP mọi nơi · current/ 1-dòng-1-SP.

## ERD (SQLite — vận hành)

```
┌─────────────────────┐         ┌──────────────────────┐
│ merchants           │         │ collections          │
│─────────────────────│         │──────────────────────│
│ PK* merchant_key    │──┐   ┌──│ PK* collection_key   │
│    slug*            │  │   │  │ FK* merchant_key     │
│    display_name     │  │   │  │    collection_id*    │
│    shop_url*        │  │   │  │    slug* / title     │
│    myshopify_domain │UQ│   │  │    intent_tier       │
│    apparel_prior*   │  │   │  │    priority_score*   │◄── Collection Priority Score
│    merchant_score*  │◄─┼───┼──│    score_version     │    (design; công thức tương lai)
│    score_updated_at │  │ F │  │    crawl_count*      │
│    first_seen*      │  │ e │  │    last_crawled_at   │
│    last_seen*       │  │ e │  └──────────┬───────────┘
└─────────────────────┘  │ d │             │ 1
                         │ b │             │ n
                         │ a │  ┌──────────▼───────────┐
                         │ c │  │ collection_crawl_stats│
                         │ k │  │──────────────────────│
┌─────────────────────┐  │   │  │ PK* stat_id          │
│ product_merchants   │  │   │  │ FK* collection_key   │
│ (Parquet, obs.)     │  │   │  │ FK* job_id           │
│─────────────────────│  │   │  │    tiles/products/   │
│    product_id*      │──┼───┼──│    new/unique_reviewed│
│ FK* merchant_key    │──┘   │  │    requests_used*    │
│    first_observed*  │      │  │    reward_r1/10/50/100│◄── R_T vector
│    last_observed*   │      │  └──────────────────────┘
│    evidence*        │      │
└─────────────────────┘      │  ┌──────────────────────┐
                             │  │ product_collections  │
                             │  │ (Parquet, n–n)       │
                             │  │──────────────────────│
                             │  │    product_id*       │
                             │  │ FK* collection_key   │
                             │  │    position          │
                             │  │    observed_at* (TS) │
                             │  └──────────────────────┘
                             │             │
┌─────────────────────┐        │             │
│ products (Parquet)  │◄───────┴─────────────┘
│ lake/ + current/    │
│─────────────────────│
│ PK* product_id      │   current/: ĐÚNG 1 dòng/product_id (writer đảm bảo)
│    url* / title*    │   lake/: mọi quan sát (TIMESTAMP phân biệt intraday)
│    price*           │
│    image_url*       │
└────────┬────────────┘
         │ 1
         ├───1 product_review_state (SQLite) — v1.1 TÁCH 2 trạng thái
         │   │ PK* product_id
         │   │ DATA:  review_count │ rating_avg │ review_status* │ confidence*
         │   │ ACCESS: fetch_status* │ last_success_at │ last_attempt_at*
         │   │ (fetch fail KHÔNG đụng data columns)
         │
         ├───n product_images (Parquet) — URL only
         │   │ (product_id*, image_url*)UQ
         │
         └───n reviews (Parquet, FUTURE) — identity nhiều tầng
             │ PK* review_id (surrogate) │ review_key_platform
             │ identity_method* │ identity_confidence* │ version* │ supersedes

┌─────────────────────┐         ┌──────────────────────┐
│ crawl_jobs          │         │ crawl_targets        │
│─────────────────────│         │──────────────────────│
│ PK* job_id          │──┐   ┌──│ PK* target_key       │
│    kind*            │  │   │  │    target_type*      │
│    target_desc*     │  │   │  │    status* (indexed) │
│    status*          │  │   │  │    priority*         │◄── scheduler ORDER BY
│    stats_json       │  │   │  │    attempts*         │
└─────────────────────┘  │   │  │    next_retry_at*    │
                         │   │  │    lease_until       │
┌─────────────────────┐  │   │  └──────────────────────┘
│ crawl_policy        │  │   │
│─────────────────────│  │   │  ┌──────────────────────┐
│ PK* policy_key      │  │   │  │ crawl_errors         │
│    policy_value*    │  │   └──│ PK* error_id │ target_key* │
│    updated_at*      │  │      └──────────────────────┘
└─────────────────────┘  │
                         │      ┌──────────────────────┐
┌─────────────────────┐  │      │ dq_violations        │
│ field_changes       │  │      │ PK* violation_id │ rule_id* │
│ (Parquet, history)  │  │      └──────────────────────┘
│ entity_type*        │  │
│ entity_key*         │◄─┘  (không FK cứng — DQ kiểm tra)
│ field_name*         │
│ old/new_value       │
│ observed_at* (TS)   │
└─────────────────────┘
```

## Review lifecycle (v1.1 — 2 trục độc lập)

```
DATA (review_status):   UNKNOWN ──tile OK, có count──► HAS_REVIEWS
                            └──tile OK, không count──► NO_REVIEWS (suy luận, conf 0.9)

ACCESS (fetch_status):  NOT_YET_FETCHED ──thử──► OK / HTTP_403 / HTTP_404 / TIMEOUT / CHALLENGE / ERROR
```

403 hôm nay, OK ngày mai → `fetch_status` đổi, `review_count` giữ nguyên giá trị
lần success gần nhất. Không còn chuyện "403 làm mất trạng thái review".

## Quan hệ P–C–M (không đổi)

- 1 SP trong nhiều collections → giữ toàn bộ edges (đã kiểm chứng).
- Collections → merchants qua `/m/<store>` (FK cứng).
- Products → merchants là observation (sitemap products không có merchant key).

## Ràng buộc toàn vẹn

| Ràng buộc | Thực thi | Ghi chú |
|---|---|---|
| PK/FK/UNIQUE SQLite (+ CHECK enums mới) | SQLite DDL | Enforce thật |
| FK logic Parquet | DQ job | Không enforce trong Parquet |
| current/: 1 dòng/product_id | **Writer + DQ R15** | Bất biến vật lý, không phụ thuộc query |
| review identity | Ingest (method+confidence) + DQ | Không mặc định hash = ID |
| `review_count >= 0`, `price > 0`, URL format | DQ R3/R4/R5 | |
