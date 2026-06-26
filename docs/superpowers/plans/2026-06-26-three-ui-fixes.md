# Three UI Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** แก้บั๊ก UI 3 จุดบนหน้าผู้ว่าฯ/สก — เวลาเป็น UTC+7, ส่วนข่าวมี thumbnail (ลิงก์ og:image), เอาปุ่ม zoom แผนที่ออก

**Architecture:** 3 fix อิสระต่อกัน — (A) ตั้ง Rails time_zone=Bangkok + JS format ด้วย timeZone กรุงเทพ; (B) `News::Fetcher` ดึง URL ของ og:image รายข่าว (parallel, แค่ลิงก์ ไม่โหลดไฟล์รูป) แล้วโชว์ thumbnail; (C) revert การห่อ map ด้วย zoom + ลบ controller/CSS

**Tech Stack:** Rails 8.1, RSpec + webmock, Stimulus, Propshaft. **ไม่มี JS test runner** → JS verify ด้วย `node --check` + มือ

## Global Constraints

- ทำงานบน branch ใหม่ (subagent-driven สร้างให้); ของเดิมต้อง green — `bundle exec rspec` ผ่านก่อน commit (ปัจจุบัน **115 examples**)
- spec: `docs/superpowers/specs/2026-06-26-three-ui-fixes-design.md`
- **A:** `config.time_zone = "Bangkok"`; JS `toLocaleTimeString("th-TH", { timeZone: "Asia/Bangkok", hour12: false })`; ข่าวไม่แตะ (pubDate มี +0700 แล้ว)
- **B:** ดึง **เฉพาะ URL** ของ og:image (server อ่าน ~40KB head, ไม่โหลดไฟล์รูป — เบราว์เซอร์โหลดเอง); parallel threads + timeout 4วิ/ตัว + `rescue→nil`; cache 5 นาทีเดิม; ไม่มีรูป → text อย่างเดียว; พังทั้งก้อน → `[]`
- **C:** ลบ map-zoom (controller + CSS + wrapper) ทั้ง governor + council; **คงไว้** ชื่อเขตตัวเล็ก mobile (`.tile span` option B) + tiles/`data-action` เดิม
- 3 fix อิสระ — ทำเรียงหรือสลับได้

---

### Task 1: เวลาเป็น UTC+7

**Files:**
- Modify: `config/application.rb:36`
- Modify: `app/javascript/controllers/fallback_controller.js:48`
- Modify: `app/javascript/controllers/council_controller.js:42`
- Test: `spec/requests/dashboard_spec.rb` (เพิ่ม)

**Interfaces:** ไม่มี (config + display)

- [ ] **Step 1: Write the failing test**

เพิ่มใน `spec/requests/dashboard_spec.rb` — และเพิ่ม `include ActiveSupport::Testing::TimeHelpers` ใต้บรรทัด `include ElectionSetup` (ให้ `travel_to` ใช้ได้):
```ruby
  it "renders the updated time in UTC+7 (Bangkok)" do
    build_election(zones: 1, candidates: 1)
    travel_to(Time.utc(2026, 6, 26, 0, 35, 0)) do
      get "/"
      expect(response.body).to include("07:35")
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "UTC+7"`
Expected: FAIL — body มี "00:35" (UTC) ไม่ใช่ "07:35"

- [ ] **Step 3: Set the Rails time zone**

`config/application.rb` บรรทัด 36 เปลี่ยนจาก `# config.time_zone = "Central Time (US & Canada)"` เป็น:
```ruby
    config.time_zone = "Bangkok"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS (รวมของเดิม)

- [ ] **Step 5: Fix the client-side formatters**

`app/javascript/controllers/fallback_controller.js` บรรทัด 48 เปลี่ยนจาก:
```js
    set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH")} น.`)
```
เป็น:
```js
    set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH", { timeZone: "Asia/Bangkok", hour12: false })} น.`)
```

`app/javascript/controllers/council_controller.js` บรรทัด 42 เปลี่ยนจาก:
```js
    if (data.updated_at) set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH")} น.`)
```
เป็น:
```js
    if (data.updated_at) set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH", { timeZone: "Asia/Bangkok", hour12: false })} น.`)
```

- [ ] **Step 6: Verify JS syntax**

Run: `node --check app/javascript/controllers/fallback_controller.js && node --check app/javascript/controllers/council_controller.js`
Expected: ไม่มี output

- [ ] **Step 7: Commit**

```bash
git add config/application.rb app/javascript/controllers/fallback_controller.js app/javascript/controllers/council_controller.js spec/requests/dashboard_spec.rb
git commit -m "Show update time in UTC+7 (config.time_zone + client timeZone)"
```

---

### Task 2: ส่วนข่าวมี thumbnail (ลิงก์ og:image)

**Files:**
- Modify: `app/services/news/fetcher.rb`
- Modify: `app/views/dashboard/_news.html.erb`
- Modify: `app/assets/stylesheets/application.css:259-260` (+ เพิ่ม 2 rule)
- Test: `spec/services/news/fetcher_spec.rb`

**Interfaces:**
- Produces: `News::Fetcher::Item = Struct.new(:title, :url, :published_at, :excerpt, :image_url)`; `News::Fetcher.og_image(url) -> String|nil`

- [ ] **Step 1: Stub article URLs by default in the spec (keep existing specs green)**

ใน `spec/services/news/fetcher_spec.rb` แก้ `before` block (เดิม `before { Rails.cache.clear }`) เป็น:
```ruby
  before do
    Rails.cache.clear
    stub_request(:get, %r{www\.dailynews\.co\.th/news/\d+/?\z}).to_return(body: "<html></html>")
  end
```
(เหตุผล: `latest` จะ fetch article เพื่อหา og:image; ของจริงไม่มีรูปก็คืน nil — แต่ใน test ต้อง stub เพราะ webmock บล็อก net; `WebMock::NetConnectNotAllowedError` ไม่ใช่ StandardError จึง rescue ในโค้ดไม่ครอบ → ต้อง stub)

- [ ] **Step 2: Write the failing tests**

เพิ่มใน `spec/services/news/fetcher_spec.rb`:
```ruby
  it "extracts the og:image URL for each item (link only)" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    stub_request(:get, "https://www.dailynews.co.th/news/1/")
      .to_return(body: '<html><head><meta property="og:image" content="https://img.example/a.jpg" /></head></html>')
    stub_request(:get, "https://www.dailynews.co.th/news/2/")
      .to_return(body: '<html><head><meta property="og:image" content="https://img.example/b.jpg" /></head></html>')
    items = described_class.latest(limit: 2)
    expect(items.map(&:image_url)).to eq(["https://img.example/a.jpg", "https://img.example/b.jpg"])
  end

  it "leaves image_url nil when the article fetch fails (items still returned)" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    stub_request(:get, %r{www\.dailynews\.co\.th/news/\d+/?\z}).to_timeout
    items = described_class.latest(limit: 2)
    expect(items.size).to eq(2)
    expect(items.map(&:image_url)).to eq([nil, nil])
  end
```

- [ ] **Step 3: Run to verify fail**

Run: `bundle exec rspec spec/services/news/fetcher_spec.rb -e og:image`
Expected: FAIL — `Item` ไม่มี member `image_url`

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
    Item = Struct.new(:title, :url, :published_at, :excerpt, :image_url)

    def self.latest(limit: 5)
      Rails.cache.fetch("news/latest/#{limit}", expires_in: 5.minutes) do
        feed = RSS::Parser.parse(fetch_xml, false)
        items = feed.items.first(limit).map do |i|
          Item.new(i.title, i.link, i.pubDate,
                   ActionController::Base.helpers.strip_tags(i.description.to_s).squish.truncate(140), nil)
        end
        images = items.map { |it| Thread.new { og_image(it.url) } }.map(&:value)
        items.each_with_index { |it, idx| it.image_url = images[idx] }
        items
      end
    rescue StandardError => e
      Rails.logger.warn("[news] feed failed: #{e.class} #{e.message}")
      []
    end

    def self.fetch_xml
      URI.open(FEED_URL, read_timeout: 5, open_timeout: 5).read
    end

    # ดึงเฉพาะ URL ของ og:image — อ่าน ~40KB แรกของ <head> เท่านั้น (ไม่โหลดไฟล์รูป)
    def self.og_image(url)
      head = URI.open(url, read_timeout: 4, open_timeout: 4) { |f| f.read(40_000) }
      head&.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i)&.captures&.first
    rescue StandardError
      nil
    end
  end
end
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec rspec spec/services/news/fetcher_spec.rb`
Expected: PASS ทั้งหมด (parse / [] on error / excerpt / og:image / fail-safe)

- [ ] **Step 6: Update the news partial (thumbnail + body wrapper)**

`app/views/dashboard/_news.html.erb` แทนบล็อก `<% items.each do |item| %> ... <% end %>` (บรรทัด 11-17) ด้วย:
```erb
      <% items.each do |item| %>
        <a class="news-item" href="<%= item.url %>" target="_blank" rel="noopener">
          <% if item.image_url.present? %>
            <img class="news-thumb" src="<%= item.image_url %>" alt="" loading="lazy">
          <% end %>
          <div class="news-body">
            <h3><%= item.title %></h3>
            <% if item.excerpt.present? %><p><%= item.excerpt %></p><% end %>
            <time><%= item.published_at&.strftime("%d/%m/%Y • %H:%M น.") %></time>
          </div>
        </a>
      <% end %>
```

- [ ] **Step 7: Update CSS (flex item + thumbnail)**

`app/assets/stylesheets/application.css`:

(a) แทน `.news-item` rule (บรรทัด 259-260) ด้วย:
```css
.news-item{display:flex;gap:12px;align-items:flex-start;border:1px solid var(--line);border-radius:14px;
  padding:12px 14px;background:#fff;transition:transform .2s,box-shadow .2s}
```

(b) เพิ่ม 2 rule หลัง `.news-item:hover{...}` (บรรทัด 261):
```css
.news-thumb{width:72px;height:72px;flex:none;object-fit:cover;border-radius:10px;background:var(--line)}
.news-body{min-width:0}
```

- [ ] **Step 8: Verify CSS balance + full suite**

Run: `ruby -e 'c=File.read("app/assets/stylesheets/application.css"); abort("MISMATCH") unless c.count("{")==c.count("}"); puts "balanced"'`
Run: `bundle exec rspec`
Expected: balanced; **118 examples** (116 หลัง Task 1 + 2 ใหม่), 0 failures

- [ ] **Step 9: Commit**

```bash
git add app/services/news/fetcher.rb app/views/dashboard/_news.html.erb app/assets/stylesheets/application.css spec/services/news/fetcher_spec.rb
git commit -m "News: show thumbnail from each article's og:image URL (link only, browser-loaded)"
```

---

### Task 3: เอา zoom แผนที่ออก

**Files:**
- Modify: `app/views/dashboard/_map_grid.html.erb`
- Modify: `app/views/council/_map.html.erb`
- Delete: `app/javascript/controllers/map_zoom_controller.js`
- Modify: `app/assets/stylesheets/application.css` (ลบ block 198-206 + บรรทัด `.map-zoom-ctl{display:flex}`)
- Test: `spec/requests/dashboard_spec.rb` (เพิ่ม), `spec/requests/council_spec.rb` (เพิ่ม)

**Interfaces:** ไม่มี

- [ ] **Step 1: Write the failing tests**

เพิ่มใน `spec/requests/dashboard_spec.rb`:
```ruby
  it "renders the map without zoom controls" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).not_to include("map-zoom")
    expect(response.body).to include('class="map-grid"')
  end
```
เพิ่มใน `spec/requests/council_spec.rb` (ภายใน `RSpec.describe "Council dashboard", type: :request do`):
```ruby
  it "renders the council map without zoom controls" do
    Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    get "/council"
    expect(response.body).not_to include("map-zoom")
    expect(response.body).to include('class="map-grid"')
  end
```

- [ ] **Step 2: Run to verify fail**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/council_spec.rb -e "without zoom"`
Expected: FAIL — body ยังมี "map-zoom"

- [ ] **Step 3: Revert the governor map partial**

แทนทั้งไฟล์ `app/views/dashboard/_map_grid.html.erb`:
```erb
<% zones = election.zones.includes(:zone_stat, vote_results: :candidate).sort_by(&:code) %>
<div id="zone-map">
  <div class="map-grid">
    <% zones.each do |z| %>
      <% leader = z.leading_candidate %>
      <button class="tile" data-zone-code="<%= z.code %>" data-action="zone-detail#show"
              style="--c: <%= leader&.color || '#C9CFD6' %>; grid-column: <%= z.grid_col %>; grid-row: <%= z.grid_row %>"
              aria-label="เขต<%= z.name %><%= " ผู้นำคะแนน: #{leader.name}" if leader %>">
        <span><%= z.name %></span>
      </button>
    <% end %>
  </div>
  <div class="legend">
    <% election.leaderboard.first(3).each do |c| %>
      <span><i style="background: <%= c.color %>"></i><%= c.name %> นำ</span>
    <% end %>
  </div>
</div>
```

- [ ] **Step 4: Revert the council map partial**

แทนทั้งไฟล์ `app/views/council/_map.html.erb`:
```erb
<% zones = election.zones.includes(:zone_stat, vote_results: :candidate).sort_by(&:code) %>
<div id="council-map"><div class="map-grid">
  <% zones.each do |z|
       w = z.vote_results.max_by(&:votes)&.candidate %>
    <button class="tile" data-zone-code="<%= z.code %>" data-action="council#show"
            style="--c: <%= w&.color || '#C9CFD6' %>; grid-column: <%= z.grid_col %>; grid-row: <%= z.grid_row %>"
            aria-label="เขต<%= z.name %><%= " ผู้ชนะ #{w.name}" if w %>"><span><%= z.name %></span></button>
  <% end %>
</div></div>
```

- [ ] **Step 5: Delete the controller**

Run: `git rm app/javascript/controllers/map_zoom_controller.js`

- [ ] **Step 6: Remove the map-zoom CSS**

`app/assets/stylesheets/application.css`:

(a) ลบทั้ง block นี้ (บรรทัด 198-206, อยู่ระหว่าง `@keyframes tileflip{...}` กับ `@media(max-width:640px){`):
```css
/* ซูมเฉพาะแผนที่ (map-zoom controller) — vp คือกล่อง pan, .map-grid คือ canvas ที่ scale */
.map-zoom{position:relative}
.map-zoom-vp{overflow:auto;-webkit-overflow-scrolling:touch;touch-action:pan-x pan-y;border-radius:10px}
.map-zoom .map-grid{transform-origin:0 0;will-change:transform}
.map-zoom-ctl{display:none;position:absolute;right:8px;bottom:8px;gap:6px;z-index:3}
.map-zoom-ctl button{width:44px;height:44px;border-radius:11px;border:1px solid rgba(255,255,255,.18);
  background:rgba(20,24,32,.72);color:#fff;font-size:20px;line-height:1;font-weight:600;
  display:grid;place-items:center;cursor:pointer;backdrop-filter:blur(6px);-webkit-backdrop-filter:blur(6px)}
.map-zoom-ctl button:active{transform:scale(.94)}
```

(b) ลบบรรทัดนี้ใน `@media(max-width:640px){...}`:
```css
  .map-zoom-ctl{display:flex}
```

- [ ] **Step 7: Run to verify pass + full suite**

Run: `bundle exec rspec`
Expected: PASS — **120 examples** (118 + 2 ใหม่), 0 failures (รวมของเดิม: tile/map-grid tests ยังผ่าน)

- [ ] **Step 8: Commit**

```bash
git add app/views/dashboard/_map_grid.html.erb app/views/council/_map.html.erb app/assets/stylesheets/application.css spec/requests/dashboard_spec.rb spec/requests/council_spec.rb
git commit -m "Remove map zoom controls/controller/CSS (keep small mobile zone labels)"
```

---

## Final Verification (หลังครบทุก task)
- [ ] `bundle exec rspec` — green (120)
- [ ] Deploy → header "อัปเดต" โชว์เวลา **+7**; รอ poll/stream แล้วเวลายัง +7 (ทุก browser)
- [ ] ส่วนข่าว: มี thumbnail (โหลดรูปตรงจาก dailynews CDN); ข่าวที่หา og:image ไม่เจอ → text อย่างเดียว
- [ ] แผนที่ (ผู้ว่าฯ + สก): **ไม่มีปุ่ม zoom**, ชื่อเขตตัวเล็ก mobile ยังอยู่, แตะเขตเปิด detail ได้

## Self-Review notes (ผู้เขียน plan ตรวจแล้ว)
- **Spec coverage:** A→Task 1, B→Task 2, C→Task 3 ครบทุก §
- **Placeholder scan:** ไม่มี TBD; โค้ดเต็มทุก step
- **Type consistency:** `Item` 5 members (`image_url` ใหม่) ใช้ตรงกัน fetcher/view; `og_image` คืน String|nil; timezone "Bangkok"/"Asia/Bangkok" ตรงกับ Global Constraints; การลบ `map-zoom` ครบทั้ง view+controller+CSS (ไม่มี reference ค้าง)
