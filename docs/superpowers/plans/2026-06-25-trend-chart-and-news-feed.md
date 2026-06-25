# Trend Chart + Election News Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ซ่อม 2 widget คอลัมน์ขวาของหน้าผู้ว่าฯ — กราฟ "คะแนนสะสม" ให้ดึง time-series จริงจาก server, และส่วนข่าวให้ดึงข่าวเลือกตั้ง กทม. จริงจาก Dailynews WordPress category feed พร้อม excerpt

**Architecture:** กราฟ — server บันทึก trend point (คะแนนทุกเบอร์) ลงตาราง `trend_points` ทุก ingest ที่คะแนนเปลี่ยน → ฝัง `trend` ใน `results.json` → Stimulus วาดเส้นจาก server (เลิกสะสมเองฝั่ง client). ข่าว — `News::Fetcher` ดึง RSS category feed + excerpt, view เป็น list ข้อความ

**Tech Stack:** Rails 8.1, RSpec + webmock, Stimulus, Propshaft, Postgres (jsonb), Solid Queue. **ไม่มี JS test runner** → โค้ด JS verify ด้วย `node --check` + มือ

## Global Constraints

- ทำงานบน branch ใหม่ (subagent-driven จะสร้างให้); ของเดิมต้อง green — รัน `bundle exec rspec` ผ่านก่อน commit (ปัจจุบัน 108 examples)
- spec อ้างอิง: `docs/superpowers/specs/2026-06-25-trend-chart-and-news-feed-design.md`
- **ข่าว:** feed = `https://www.dailynews.co.th/news/special/election-bangkok-69/feed/` (override ด้วย ENV `NEWS_FEED_URL`); excerpt = strip HTML + squish + truncate **140**; แสดง **5** ข่าว; feed พัง → คืน `[]`; feed ไม่มีรูป (ไม่ทำ thumbnail)
- **กราฟ:** ตาราง `trend_points` (jsonb `votes` = `{"เบอร์" => คะแนนรวม}` — **key เป็น String**); บันทึกเมื่อ governor ingest มีการเปลี่ยน (+ admin แก้มือ); เก็บ **300** จุด (prune), serve **60** จุดใน snapshot; **governor เท่านั้น** (council ไม่มี key `trend`)
- ใช้ DB table ไม่ใช่ cache (กัน evict ตอน peak)

**ลำดับ:** Task 1 (ข่าว, อิสระ) · Task 2 → 3 → 4 (กราฟ: store → snapshot/hooks → client)

---

### Task 1: News — category feed + excerpt

**Files:**
- Modify: `app/services/news/fetcher.rb`
- Modify: `spec/fixtures/news/feed.xml`
- Modify: `spec/services/news/fetcher_spec.rb`
- Modify: `app/views/dashboard/_news.html.erb`
- Modify: `app/assets/stylesheets/application.css` (lines 258-270 + 487-493)

**Interfaces:**
- Produces: `News::Fetcher::Item = Struct.new(:title, :url, :published_at, :excerpt)`; `News::Fetcher.latest(limit: 5) -> [Item]`

- [ ] **Step 1: Add `<description>` to the test fixture**

แทนทั้งไฟล์ `spec/fixtures/news/feed.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Dailynews</title>
    <item>
      <title>ข่าวเลือกตั้ง 1</title>
      <link>https://www.dailynews.co.th/news/1/</link>
      <pubDate>Sun, 28 Jun 2026 18:45:00 +0700</pubDate>
      <description><![CDATA[สรุปผลคะแนนเขตเลือกตั้งล่าสุด พร้อมบรรยากาศการนับคะแนนทั่วกรุงเทพมหานคร]]></description>
    </item>
    <item>
      <title>ข่าวเลือกตั้ง 2</title>
      <link>https://www.dailynews.co.th/news/2/</link>
      <pubDate>Sun, 28 Jun 2026 19:20:00 +0700</pubDate>
      <description><![CDATA[อัปเดตคะแนนผู้สมัครผู้ว่าฯ กทม.]]></description>
    </item>
  </channel>
</rss>
```

- [ ] **Step 2: Write the failing excerpt test**

เพิ่มใน `spec/services/news/fetcher_spec.rb` (ภายใน `RSpec.describe News::Fetcher do`):
```ruby
  it "includes a plain-text excerpt from the description" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    item = described_class.latest(limit: 1).first
    expect(item.excerpt).to eq("สรุปผลคะแนนเขตเลือกตั้งล่าสุด พร้อมบรรยากาศการนับคะแนนทั่วกรุงเทพมหานคร")
  end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bundle exec rspec spec/services/news/fetcher_spec.rb -e excerpt`
Expected: FAIL — `Item` ไม่มี member `excerpt` (NoMethodError) / nil

- [ ] **Step 4: Implement the fetcher**

แทนทั้งไฟล์ `app/services/news/fetcher.rb`:
```ruby
require "rss"
require "open-uri"

module News
  # ดึงข่าวเลือกตั้ง กทม. จากหมวด WordPress ของ dailynews.co.th
  # พังเมื่อไหร่คืน [] — หน้าเว็บผลคะแนนห้ามล่มเพราะข่าว
  class Fetcher
    FEED_URL = ENV.fetch("NEWS_FEED_URL", "https://www.dailynews.co.th/news/special/election-bangkok-69/feed/")
    Item = Struct.new(:title, :url, :published_at, :excerpt)

    def self.latest(limit: 5)
      Rails.cache.fetch("news/latest/#{limit}", expires_in: 5.minutes) do
        feed = RSS::Parser.parse(fetch_xml, false)
        feed.items.first(limit).map do |i|
          Item.new(i.title, i.link, i.pubDate,
                   ActionController::Base.helpers.strip_tags(i.description.to_s).squish.truncate(140))
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[news] feed failed: #{e.class} #{e.message}")
      []
    end

    def self.fetch_xml
      URI.open(FEED_URL, read_timeout: 5, open_timeout: 5).read
    end
  end
end
```

- [ ] **Step 5: Run to verify pass (incl. existing news specs)**

Run: `bundle exec rspec spec/services/news/fetcher_spec.rb`
Expected: PASS ทั้งหมด (3 examples: parse / [] on error / excerpt)

- [ ] **Step 6: Update the news partial**

แทนทั้งไฟล์ `app/views/dashboard/_news.html.erb`:
```erb
<% items = News::Fetcher.latest(limit: 5) %>
<section class="card sec-news" id="news" aria-label="ข่าวจาก Dailynews">
  <div class="card-head">
    <svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5h13v14H6a2 2 0 0 1-2-2V5Z"/><path d="M17 8h3v9a2 2 0 0 1-2 2h-1M8 9h5M8 13h5M8 17h3"/></svg>
    <h2>เกาะติดจาก Dailynews</h2>
  </div>
  <div class="news-list">
    <% if items.empty? %>
      <p style="padding: 14px 16px; color: var(--muted)">ติดตามข่าวเลือกตั้งทั้งหมดได้ที่ dailynews.co.th</p>
    <% else %>
      <% items.each do |item| %>
        <a class="news-item" href="<%= item.url %>" target="_blank" rel="noopener">
          <h3><%= item.title %></h3>
          <% if item.excerpt.present? %><p><%= item.excerpt %></p><% end %>
          <time><%= item.published_at&.strftime("%d/%m/%Y • %H:%M น.") %></time>
        </a>
      <% end %>
    <% end %>
  </div>
  <a class="news-more" href="https://www.dailynews.co.th/news/special/election-bangkok-69/" target="_blank" rel="noopener">อ่านข่าวเลือกตั้งทั้งหมด →</a>
</section>
```

- [ ] **Step 7: Update CSS (single-column item + excerpt; remove orphaned thumb)**

`app/assets/stylesheets/application.css`:

(a) แทน `.news-item` rule (บรรทัด 259-261) ด้วย:
```css
.news-item{display:block;border:1px solid var(--line);border-radius:14px;padding:12px 14px;background:#fff;
  transition:transform .2s,box-shadow .2s}
```

(b) ลบ rule `.news-thumb{...}` + `.news-thumb svg{...}` (บรรทัด 263-265) ทิ้ง (element ถูกเอาออกแล้ว — orphaned)

(c) เพิ่ม rule excerpt หลัง `.news-item h3{...}` (บรรทัด 266):
```css
.news-item p{margin:5px 0 0;font-size:12.5px;color:var(--muted);line-height:1.5;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
```

(d) ลบ dark-mode `html[data-theme="dark"] .news-thumb{...}` + `.news-thumb svg{...}` (บรรทัด 490-493) ทิ้ง (orphaned)

- [ ] **Step 8: Verify CSS balance + full suite**

Run: `ruby -e 'c=File.read("app/assets/stylesheets/application.css"); abort("MISMATCH") unless c.count("{")==c.count("}"); puts "balanced"'`
Run: `bundle exec rspec`
Expected: balanced; 109 examples (108 + 1 new), 0 failures

- [ ] **Step 9: Commit**

```bash
git add app/services/news/fetcher.rb spec/fixtures/news/feed.xml spec/services/news/fetcher_spec.rb app/views/dashboard/_news.html.erb app/assets/stylesheets/application.css
git commit -m "News: pull BKK-election WordPress category feed with excerpts (drop empty thumb)"
```

---

### Task 2: Trend store + recorder (`trend_points` + `Election#record_trend_point!`)

**Files:**
- Create: `db/migrate/<timestamp>_create_trend_points.rb` (ผ่าน generator)
- Create: `app/models/trend_point.rb`
- Modify: `app/models/election.rb` (เพิ่ม `has_many :trend_points` + `KEEP_TREND_POINTS` + `#record_trend_point!`)
- Test: `spec/models/election_spec.rb` (เพิ่ม)

**Interfaces:**
- Produces: ตาราง `trend_points(election_id, captured_at, votes jsonb)`; `TrendPoint < ApplicationRecord` (`belongs_to :election`); `Election#record_trend_point! -> TrendPoint` (สร้าง 1 จุด `votes` = `{"เบอร์"(String) => คะแนนรวม(Int)}` ของผู้สมัครทุกคน, prune เหลือ `Election::KEEP_TREND_POINTS` = 300); `Election#trend_points` association — ใช้โดย Task 3

- [ ] **Step 1: Generate + edit migration**

Run: `bin/rails generate migration CreateTrendPoints`
แล้วแทนเนื้อไฟล์ `db/migrate/<timestamp>_create_trend_points.rb`:
```ruby
class CreateTrendPoints < ActiveRecord::Migration[8.1]
  def change
    create_table :trend_points do |t|
      t.references :election, null: false, foreign_key: true
      t.datetime :captured_at, null: false
      t.jsonb :votes, null: false, default: {}
      t.timestamps
    end
    add_index :trend_points, [:election_id, :captured_at]
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate`
Expected: ตาราง `trend_points` ถูกสร้าง; `db/schema.rb` อัปเดต

- [ ] **Step 3: Write failing model specs**

เพิ่มใน `spec/models/election_spec.rb`:
```ruby
  describe "#record_trend_point!" do
    it "captures one point with all candidates' totals (string keys)" do
      e = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
      e.candidates.create!(number: 1, name: "A", party: "พรรคก", color: "#0E8A45")
      e.candidates.create!(number: 2, name: "B", party: "พรรคข", color: "#1a73e8")
      z = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
      ResultWriter.new(z, source: "api").apply!({ 1 => 100, 2 => 40 })

      expect { e.record_trend_point! }.to change { e.trend_points.count }.by(1)
      pt = TrendPoint.order(:id).last
      expect(pt.votes).to eq({ "1" => 100, "2" => 40 })
      expect(pt.captured_at).to be_within(5.seconds).of(Time.current)
    end

    it "prunes to the most recent KEEP_TREND_POINTS rows" do
      e = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
      e.candidates.create!(number: 1, name: "A", party: "ก", color: "#0E8A45")
      (Election::KEEP_TREND_POINTS + 5).times { e.record_trend_point! }
      expect(e.trend_points.count).to eq(Election::KEEP_TREND_POINTS)
    end
  end
```

- [ ] **Step 4: Run to verify fail**

Run: `bundle exec rspec spec/models/election_spec.rb -e record_trend_point`
Expected: FAIL — `uninitialized constant ... TrendPoint` / `undefined method 'record_trend_point!'`

- [ ] **Step 5: Create the model**

สร้าง `app/models/trend_point.rb`:
```ruby
class TrendPoint < ApplicationRecord
  belongs_to :election
end
```

- [ ] **Step 6: Add association + recorder to Election**

ใน `app/models/election.rb`: เพิ่ม `has_many :trend_points, dependent: :destroy` ใต้บรรทัด `has_many :zones, dependent: :destroy`, และเพิ่ม method ก่อน `end` ของ class:
```ruby
  KEEP_TREND_POINTS = 300

  # บันทึกคะแนนรวมของผู้สมัครทุกคน ณ ขณะนี้เป็น 1 จุดในกราฟเทรนด์ (governor)
  def record_trend_point!
    votes = leaderboard.to_h { |c| [c.number.to_s, c.total_votes.to_i] }
    point = trend_points.create!(captured_at: Time.current, votes: votes)
    stale = trend_points.order(id: :desc).offset(KEEP_TREND_POINTS).pluck(:id)
    trend_points.where(id: stale).delete_all if stale.any?
    point
  end
```

- [ ] **Step 7: Run to verify pass**

Run: `bundle exec rspec spec/models/election_spec.rb`
Expected: PASS (รวม council_seat_breakdown เดิม)

- [ ] **Step 8: Commit**

```bash
git add db/migrate db/schema.rb app/models/trend_point.rb app/models/election.rb spec/models/election_spec.rb
git commit -m "Add trend_points store + Election#record_trend_point! (capped time-series)"
```

---

### Task 3: Snapshot `trend` key + record hooks (ingest + admin)

**Files:**
- Modify: `app/services/results_snapshot.rb` (governor_json เพิ่ม `trend:`)
- Modify: `app/jobs/ingest_poll_job.rb:46-52` (record ใน changed&&governor block)
- Modify: `app/controllers/admin/zone_results_controller.rb:43-46` (record หลังแก้มือ)
- Test: `spec/services/results_snapshot_spec.rb` (เพิ่ม), `spec/jobs/ingest_poll_job_spec.rb` (เพิ่ม), `spec/requests/admin_spec.rb` (เพิ่ม)

**Interfaces:**
- Consumes: `Election#record_trend_point!`, `Election#trend_points` (Task 2)
- Produces: `results.json` (governor) key `trend: [{ t: ISO8601, votes: {"เบอร์"=>คะแนน} }, ...]` (≤60 จุด, เรียงเก่า→ใหม่) — ใช้โดย Task 4

- [ ] **Step 1: Write failing snapshot spec**

เพิ่มใน `spec/services/results_snapshot_spec.rb`:
```ruby
  it "governor snapshot includes a trend series; council has none" do
    g = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
    g.candidates.create!(number: 1, name: "A", party: "ก", color: "#0E8A45")
    g.record_trend_point!
    g.record_trend_point!
    trend = ResultsSnapshot.new(g).as_json[:trend]
    expect(trend.size).to eq(2)
    expect(trend.first).to include(:t, :votes)

    c = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    expect(ResultsSnapshot.new(c).as_json).not_to have_key(:trend)
  end
```

- [ ] **Step 2: Run to verify fail**

Run: `bundle exec rspec spec/services/results_snapshot_spec.rb -e "trend series"`
Expected: FAIL — `trend` is nil

- [ ] **Step 3: Add `trend` to governor_json**

`app/services/results_snapshot.rb`: ในเมธอด `governor_json` เพิ่ม key `trend:` ต่อจาก `zones: ...` (ก่อน `}` ปิด hash):
```ruby
      trend: @election.trend_points.order(:captured_at).last(60).map { |p|
        { t: p.captured_at.iso8601, votes: p.votes }
      }
```
(วาง comma หลัง block `zones:` ให้ถูก; council_json ไม่แตะ)

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/services/results_snapshot_spec.rb`
Expected: PASS

- [ ] **Step 5: Write failing ingest-hook spec**

เพิ่มใน `spec/jobs/ingest_poll_job_spec.rb` (ภายใน `RSpec.describe IngestPollJob do`, ใช้ scaffold เดิม — `before` block seed candidates + stub Ingest::Client/SnapshotPublisher/ResultsBroadcaster อยู่แล้ว):
```ruby
  it "records a trend point on a governor poll that changes results" do
    expect { described_class.perform_now }.to change { election.trend_points.count }.by(1)
  end
```

- [ ] **Step 6: Run to verify fail**

Run: `bundle exec rspec spec/jobs/ingest_poll_job_spec.rb -e "records a trend point"`
Expected: FAIL — เปลี่ยนจาก 0 → ยังไม่เพิ่ม (hook ยังไม่มี)

- [ ] **Step 7: Add the ingest hook**

`app/jobs/ingest_poll_job.rb`: ในบล็อก `if changed && kind == "governor"` เพิ่ม `election.record_trend_point!` เป็นบรรทัดแรกของ begin (ก่อน broadcast). บล็อกใหม่ (แทนบรรทัด 46-52):
```ruby
    if changed && kind == "governor"
      begin
        election.record_trend_point!
        ResultsBroadcaster.new(election).broadcast_all
      rescue StandardError => e
        Rails.logger.error("[ingest:#{kind}] broadcast failed: #{e.class} #{e.message}")
      end
    end
```

- [ ] **Step 8: Run to verify pass**

Run: `bundle exec rspec spec/jobs/ingest_poll_job_spec.rb`
Expected: PASS ทั้งไฟล์

- [ ] **Step 9: Write failing admin-hook spec**

เพิ่มใน `spec/requests/admin_spec.rb` (ภายใน `describe "เมื่อ login แล้ว"`, หลัง `before { sign_in_as(admin) }`):
```ruby
    it "records a trend point after a confirmed manual save" do
      expect {
        patch admin_zone_result_path(zone), params: { confirm: "1", votes: { "1" => "999" } }
      }.to change { election.trend_points.count }.by(1)
    end
```

- [ ] **Step 10: Run to verify fail**

Run: `bundle exec rspec spec/requests/admin_spec.rb -e "records a trend point"`
Expected: FAIL — count ไม่เพิ่ม (hook ยังไม่มี)

- [ ] **Step 11: Add the admin hook**

`app/controllers/admin/zone_results_controller.rb`: ในบล็อก `if changed` (บรรทัด 43-46) เพิ่ม `election.record_trend_point!` ก่อน publish:
```ruby
    if changed
      election.record_trend_point!
      ResultsBroadcaster.new(election).broadcast_all
      SnapshotPublisher.new(election).publish
    end
```

- [ ] **Step 12: Run full suite (regression)**

Run: `bundle exec rspec`
Expected: PASS ทั้งหมด (เพิ่ม 3 examples จาก task นี้)

- [ ] **Step 13: Commit**

```bash
git add app/services/results_snapshot.rb app/jobs/ingest_poll_job.rb app/controllers/admin/zone_results_controller.rb spec/services/results_snapshot_spec.rb spec/jobs/ingest_poll_job_spec.rb spec/requests/admin_spec.rb
git commit -m "Publish trend series in governor snapshot; record points on ingest + manual save"
```

---

### Task 4: Client — draw chart from server trend

**Files:**
- Modify: `app/javascript/controllers/trend_chart_controller.js`

**Interfaces:**
- Consumes: `results.json` key `trend: [{t, votes:{"เบอร์"=>คะแนน}}]` + `candidates` (Task 3); DOM: `#chart-legend`, controller element `.chart-svg`
- Produces: ไม่มี (UI behavior)

> **ไม่มี JS test runner** → verify ด้วย `node --check` + มือ (Step 3)

- [ ] **Step 1: Rewrite the controller to draw from server trend**

แทนทั้งไฟล์ `app/javascript/controllers/trend_chart_controller.js`:
```js
import { Controller } from "@hotwired/stimulus"

const cdnBase = () => document.querySelector('meta[name="snapshot-cdn"]')?.content || ""

// กราฟคะแนนสะสม 3 อันดับแรก — วาดเส้นจาก time-series ที่ server ส่งมาใน results.json (key: trend)
// ไม่สะสมเองฝั่ง client แล้ว → โหลดมาเห็นเส้นเต็มทันที + รอด reload
export default class extends Controller {
  connect() {
    this.poll()
    this.timer = setInterval(() => this.poll(), 30000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    try {
      const res = await fetch(`${cdnBase()}/results.json`, { cache: "no-store" })
      if (!res.ok) return
      this.draw(await res.json())
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  draw(data) {
    const W = 600, H = 200, P = 8
    const top3 = (data.candidates || []).slice(0, 3)
    const trend = data.trend || []
    const series = top3.map(c => trend.map(pt => Number(pt.votes?.[String(c.number)] ?? 0)))
    const max = Math.max(1, ...series.flat()) * 1.08
    const n = trend.length

    const path = pts => pts.map((v, i) =>
      `${i === 0 ? "M" : "L"}${(P + i * (W - 2 * P) / Math.max(1, n - 1)).toFixed(1)},` +
      `${(H - P - (v / max) * (H - 2 * P)).toFixed(1)}`).join(" ")

    this.element.innerHTML =
      [40, 80, 120, 160].map(y =>
        `<line x1="0" y1="${y}" x2="${W}" y2="${y}" stroke="rgba(135,142,165,.25)" stroke-width="1"/>`).join("") +
      top3.map((c, idx) => {
        const pts = series[idx]
        if (pts.length === 0) return ""
        const lastX = (P + (n - 1) * (W - 2 * P) / Math.max(1, n - 1)).toFixed(1)
        const lastY = (H - P - (pts[pts.length - 1] / max) * (H - 2 * P)).toFixed(1)
        return `<path d="${path(pts)} L${lastX},${H - P} L${P},${H - P} Z" fill="${c.color}" opacity="0.07"/>` +
               `<path d="${path(pts)}" fill="none" stroke="${c.color}" stroke-width="2.5" stroke-linejoin="round"/>` +
               `<circle cx="${lastX}" cy="${lastY}" r="4" fill="${c.color}"/>`
      }).join("")

    const legend = document.getElementById("chart-legend")
    if (legend) legend.innerHTML = top3.map(c =>
      `<span><i style="background:${c.color}"></i>${c.name}</span>`).join("")
  }
}
```

- [ ] **Step 2: Verify syntax**

Run: `node --check app/javascript/controllers/trend_chart_controller.js`
Expected: ไม่มี output (ผ่าน)

- [ ] **Step 3: Manual verification (DevTools, หลัง deploy)**

1. เปิด `/` หลังมี trend point ≥2 จุด → กราฟแสดง **เส้น** 3 สีตั้งแต่โหลด (ไม่ใช่จุดเดียว)
2. reload หน้า → เส้นยังอยู่ (ไม่รีเซ็ต)
3. legend แสดงชื่อ top-3

- [ ] **Step 4: Commit**

```bash
git add app/javascript/controllers/trend_chart_controller.js
git commit -m "Trend chart: draw from server-provided time-series instead of client accumulation"
```

---

## Final Verification (หลังครบทุก task)
- [ ] `bundle exec rspec` — green (≈ 108 + 6 ใหม่)
- [ ] Deploy → `/` ส่วนข่าวแสดง 5 ข่าวเลือกตั้งจริง + excerpt + เวลา (ไม่มีกล่องรูปว่าง)
- [ ] หลัง ingest ≥2 รอบที่คะแนนเปลี่ยน → กราฟ "คะแนนสะสม" แสดงเส้น top-3 ตั้งแต่โหลด + รอด reload
- [ ] `curl results.json` มี key `trend` (governor) / `results-council.json` ไม่มี

## Self-Review notes (ผู้เขียน plan ตรวจแล้ว)
- **Spec coverage:** A(ข่าว)→Task 1; B1(table)+B2(recorder)→Task 2; B3(hooks)+B4(snapshot)→Task 3; B5(client)→Task 4. ครบทุก §
- **Placeholder scan:** ไม่มี TBD; โค้ดเต็มทุก step (`<timestamp>` = generator เติม)
- **Type consistency:** `votes` key เป็น String ตลอด (recorder `.to_s`, jsonb, client `String(c.number)`); `trend: [{t, votes}]` shape ตรงกัน Task 3 produce ↔ Task 4 consume; `KEEP_TREND_POINTS=300`, serve `last(60)`, news `limit:5`/truncate `140` ตรงกับ Global Constraints
