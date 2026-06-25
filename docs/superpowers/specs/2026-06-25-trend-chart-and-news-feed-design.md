# Overview Trend Chart + Election News Feed — Design

**Date:** 2026-06-25
**Status:** Design — pending user review
**Topic:** ซ่อม 2 widget คอลัมน์ขวาของหน้าผู้ว่าฯ: (1) กราฟ "คะแนนสะสม 3 อันดับแรก" ที่ไม่ขึ้น และ (2) ส่วนข่าวที่เป็น static ให้ดึงข่าวเลือกตั้ง กทม. จริงจาก Dailynews

---

## 1. เป้าหมาย & บริบท

จาก production: การ์ด "สถิติภาพรวม" แสดงตัวเลข turnout/บัตรเสีย/ไม่ประสงค์ฯ ได้ แต่**กราฟว่าง** (เห็นแค่ grid + จุดเดียวต่อผู้สมัคร) และการ์ด "เกาะติดจาก Dailynews" เป็น**ลิงก์ static** ไม่มีข่าวจริง

**สาเหตุที่ตรวจพบ:**
- กราฟ: `app/javascript/controllers/trend_chart_controller.js` สะสม time-series เองฝั่ง client (module-level `history` Map, push คะแนนใหม่ทุก poll 30วิ) → เริ่มจากว่าง → ตอนโหลดมี 1 จุด/ผู้สมัคร = วาดได้แค่จุด ไม่มีเส้น; ไม่รอด reload; ถ้าคะแนนนิ่งไม่เพิ่มจุด **ไม่มี time-series ฝั่ง server เลย**
- ข่าว: `app/services/news/fetcher.rb` ดึง RSS รวมของเว็บ (`/feed/`) ไม่เจาะหมวดเลือกตั้ง; prod คืน empty → แสดง fallback static

**ยืนยันด้วยการทดสอบจริง:**
- WordPress category feed ใช้ได้: `https://www.dailynews.co.th/news/special/election-bangkok-69/feed/` → HTTP 200, `application/rss+xml`, มี 12 `<item>` ข่าวเลือกตั้ง กทม. จริง
- feed **ไม่มีรูป** (ไม่มี media:content/thumbnail/enclosure/content:encoded) — มี title, link, pubDate, `<description>` (CDATA plain text สะอาด)
- WP REST `/wp-json/wp/v2/posts` คืน `[]` (ปิด/กรอง) → ใช้ RSS feed ไม่ใช่ REST

## 2. Component A — ข่าวจาก category feed + excerpt

**A1. `app/services/news/fetcher.rb`**
- เปลี่ยน default `FEED_URL` → `https://www.dailynews.co.th/news/special/election-bangkok-69/feed/` (ยัง override ด้วย ENV `NEWS_FEED_URL` ได้)
- เพิ่มฟิลด์ `excerpt` ใน `Item` struct: `Item = Struct.new(:title, :url, :published_at, :excerpt)`
- map `excerpt` จาก `<description>`: strip HTML + ตัดช่องว่างซ้ำ + truncate 140 ตัว
  ```ruby
  excerpt = ActionController::Base.helpers.strip_tags(i.description.to_s).squish.truncate(140)
  ```
- `limit` default → **5** (feed มี 12, การ์ดมีที่ว่าง)
- พฤติกรรม fail-safe เดิม: error → คืน `[]` (หน้าเว็บห้ามล่มเพราะข่าว); cache 5 นาที (เดิม)

**A2. `app/views/dashboard/_news.html.erb`**
- ลบ `<div class="news-thumb"></div>` (feed ไม่มีรูป → กล่องว่างดูเสีย)
- แต่ละ item: หัวข้อ + **excerpt** (สี muted, จำกัด ~2 บรรทัด) + เวลา
- เคส empty คงเดิม (ข้อความ "ติดตามข่าวเลือกตั้งทั้งหมดได้ที่ dailynews.co.th")
- `.news-more` ลิงก์ → ชี้ไปหน้าหมวด `https://www.dailynews.co.th/news/special/election-bangkok-69/` (เดิมชี้ root)

**A3. CSS** (`application.css`): ปรับ `.news-item`/`.news-thumb` ให้ layout ไม่พังหลังเอา thumb ออก + เพิ่มสไตล์ excerpt (`.news-item p` muted, `-webkit-line-clamp:2`). แตะเฉพาะ block ข่าว

## 3. Component B — กราฟเทรนด์จริงจาก server

**Data flow:** ingest ทุก 30วิ (เมื่อคะแนนเปลี่ยน) → บันทึกจุดลง DB → `ResultsSnapshot` ฝัง `trend` ใน `results.json` → client วาดเส้นจาก server (เลิกสะสมเอง)

**B1. ตาราง `trend_points` (migration)**
```ruby
create_table :trend_points do |t|
  t.references :election, null: false, foreign_key: true
  t.datetime :captured_at, null: false
  t.jsonb :votes, null: false, default: {}   # { "เบอร์" => คะแนนรวม } ของผู้สมัครทุกคน ณ เวลานั้น
  t.timestamps
end
add_index :trend_points, [:election_id, :captured_at]
```
- เก็บผู้สมัครทุกคน (≤18) ต่อจุด → กราฟเลือก top-3 ปัจจุบันมาวาด series ของแต่ละคนได้แม้อันดับสลับ
- **หมายเหตุ jsonb:** key เป็น String ("1","2",...) เมื่อ serialize เป็น JSON

**B2. `TrendPoint` model + `Election#record_trend_point!`**
```ruby
class TrendPoint < ApplicationRecord
  belongs_to :election
end
```
```ruby
# Election
has_many :trend_points, dependent: :destroy

KEEP_TREND_POINTS = 300
def record_trend_point!
  votes = leaderboard.to_h { |c| [c.number, c.total_votes.to_i] }
  trend_points.create!(captured_at: Time.current, votes: votes)
  stale = trend_points.order(captured_at: :desc).offset(KEEP_TREND_POINTS).pluck(:id)
  trend_points.where(id: stale).delete_all if stale.any?
end
```

**B3. บันทึกจุด — hook**
- `app/jobs/ingest_poll_job.rb`: ภายในบล็อก `if changed && kind == "governor"` (ที่ broadcast) → เรียก `election.record_trend_point!` **ก่อน** broadcast/publish (เพื่อให้ snapshot ที่ publish หลังจากนั้นมีจุดล่าสุด)
- `app/controllers/admin/zone_results_controller.rb`: หลัง apply คะแนน manual สำเร็จ (governor) ก่อน publish → `Election.current.record_trend_point!` (ให้การแก้มือสะท้อนในกราฟ)

**B4. `app/services/results_snapshot.rb#governor_json`** เพิ่ม key:
```ruby
trend: @election.trend_points.order(:captured_at).last(60).map { |p|
  { t: p.captured_at.iso8601, votes: p.votes }
}
```
(council_json ไม่แตะ — กราฟนี้ governor เท่านั้น)

**B5. `app/javascript/controllers/trend_chart_controller.js`** เขียนใหม่:
- ลบ module-level `history` accumulation
- `poll()` fetch `results.json` ทุก 30วิ → `draw(data)`
- `draw(data)`: `top3 = data.candidates.slice(0,3)`; `trend = data.trend || []`; series ของแต่ละผู้สมัคร = `trend.map(p => p.votes[String(c.number)] ?? 0)`; วาด path เส้น + พื้นที่ + จุดปลาย (เหมือนสไตล์เดิม) โดย scale จาก max ของ series ที่ plot
- legend จาก top3 (เดิม)
- เคส `trend.length < 1`: ยังไม่มีจุด (ต้นคืน) → วาดเฉพาะ grid/ว่างไว้ก่อน, จะเต็มเมื่อ ingest บันทึกจุดแรก
- **โหลดมาเห็นเส้นเต็มทันที + รอด reload** เพราะ series มาจาก server

## 4. ขอบเขต & การตัดสินใจ
- เก็บ DB **300 จุด** (prune), serve **60 จุด** ใน snapshot · ปรับได้
- ใช้ DB table (ไม่ใช่ cache) เพื่อกัน evict ตอน peak — สอดคล้องกับ kill-switch (`live_streaming` column)
- ข่าว: ไม่มี thumbnail (feed ไม่มี; ไม่ดึง og:image รายข่าวเพราะช้า/เปราะ) → list ข้อความ + excerpt
- council ไม่มีกราฟเทรนด์ (scope governor)

## 5. Verification
1. `News::Fetcher.latest` (stub feed ผ่าน webmock) → คืน items มี title/url/published_at/excerpt; feed พัง → `[]`
2. `Election#record_trend_point!` → สร้าง 1 row (votes map ครบทุกเบอร์), prune เหลือ ≤300
3. `ResultsSnapshot governor_json[:trend]` → array ของ `{t, votes}` (≤60), council ไม่มี key นี้
4. `IngestPollJob` (governor, มีการเปลี่ยน) → trend_points เพิ่ม 1
5. JS (manual หลัง deploy): โหลด `/` → กราฟมีเส้น top-3 ตั้งแต่แรก, reload แล้วยังอยู่; ส่วนข่าวแสดง 5 ข่าวเลือกตั้งจริง + excerpt + เวลา
6. suite เดิมเขียว (108) + tests ใหม่
