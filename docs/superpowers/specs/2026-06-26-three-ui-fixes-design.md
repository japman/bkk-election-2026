# Three UI Fixes — Design (timezone, news thumbnails, remove map zoom)

**Date:** 2026-06-26
**Status:** Design — pending user review
**Topic:** บั๊ก UI 3 จุดบนหน้าผู้ว่าฯ/สก: (1) เวลา "อัปเดต" โชว์ UTC ต้องเป็น UTC+7, (2) ส่วนข่าวเพิ่ม thumbnail (ลิงก์ og:image), (3) เอาปุ่ม zoom แผนที่ออก

3 จุดเล็ก + อิสระต่อกัน → 1 spec, 3 component (plan ~3 task)

---

## 1. Component A — เวลาเป็น UTC+7

**ปัญหา:** `config.time_zone` ไม่ได้ตั้ง → Rails = UTC → `_header_status.html.erb:10` (`Time.current.strftime("%H:%M:%S")`) โชว์ UTC (เช่น 00:35 = 07:35 ของไทย). ข่าวไม่กระทบ (RSS pubDate มี `+0700` อยู่แล้ว).

**A1. Server:** `config/application.rb` ตั้ง `config.time_zone = "Bangkok"` (DB ยังเก็บ UTC ผ่าน `default_timezone = :utc` ปกติ — ไม่แตะ). → `Time.current` / `Time.current.iso8601` / strftime เป็น +7

**A2. Client:** snapshot `updated_at` (ISO มี offset) ถูก format ที่ client ด้วย `toLocaleTimeString("th-TH")` ซึ่งใช้ timezone ของ browser → ต้องบังคับเป็นกรุงเทพ:
- `app/javascript/controllers/fallback_controller.js:48` และ `app/javascript/controllers/council_controller.js:42`: เปลี่ยน
  ```js
  new Date(data.updated_at).toLocaleTimeString("th-TH")
  ```
  เป็น
  ```js
  new Date(data.updated_at).toLocaleTimeString("th-TH", { timeZone: "Asia/Bangkok", hour12: false })
  ```

**Verify:** request spec ด้วย `travel_to(Time.utc(2026,6,26,0,35,0))` → header มี "07:35"; JS verify มือ

## 2. Component B — รูปข่าวเล็ก (ลิงก์ og:image เท่านั้น)

**ปัญหา:** category feed ไม่มีรูป. ต้องการ thumbnail. **ดึงเฉพาะ URL ของ og:image** (server ไม่โหลด/ไม่ proxy ไฟล์รูป — เบราว์เซอร์โหลดรูปตรงจาก dailynews.co.th เอง)

**B1. `app/services/news/fetcher.rb`:**
- `Item` struct เพิ่มฟิลด์: `Item = Struct.new(:title, :url, :published_at, :excerpt, :image_url)`
- หลัง parse RSS items → ดึง og:image URL ของแต่ละ item แบบ **parallel (threads) + timeout 4วิ/ตัว + rescue→nil**; ผลรวมยังถูก cache 5 นาทีเดิม (amortize)
- helper `self.og_image(url)`:
  - อ่านเฉพาะ ~40KB แรกของ article HTML (og:image อยู่ใน `<head>`): `URI.open(url, read_timeout: 4, open_timeout: 4) { |f| f.read(40_000) }`
  - regex `/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i` → คืน URL ที่ match หรือ `nil`
  - `rescue StandardError → nil` (ดึงรูปล้มไม่ทำให้ข่าวพัง)
- fail-safe เดิมคงไว้ (ทั้งก้อนล้ม → `[]`)

**B2. `app/views/dashboard/_news.html.erb`:** ห่อ text ใน `.news-body` + ใส่ thumbnail ซ้ายเมื่อมี `image_url`:
```erb
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
```

**B3. CSS (`application.css`):** `.news-item` เป็น flex (thumb ซ้าย + body ขวา); ไม่มีรูป → body เต็ม
```css
.news-item{display:flex;gap:12px;align-items:flex-start;border:1px solid var(--line);border-radius:14px;
  padding:12px 14px;background:#fff;transition:transform .2s,box-shadow .2s}
.news-thumb{width:72px;height:72px;flex:none;object-fit:cover;border-radius:10px;background:var(--line)}
.news-body{min-width:0}
```
(`.news-item p` excerpt rule เดิมคงไว้; dark-mode `.news-item` เดิมคงไว้)

**Verify:** spec — stub `fetch_xml` (RSS fixture) + webmock article URLs คืน HTML ที่มี `og:image` → `item.image_url` == URL นั้น; og fetch ล้ม → `image_url` nil แต่ item ยังอยู่. หน้าเว็บ: thumb แสดงเมื่อมีรูป

**ข้อแลกเปลี่ยน:** ตอน news cache หมด (ทุก 5 นาที) 1 request ที่ origin ช้าขึ้น ~≤4วิ (ดึง ~5 head พร้อมกัน) — edge-cache + timeout + fail-safe คุมอยู่

## 3. Component C — เอา zoom แผนที่ออก

**ปัญหา:** ปุ่ม zoom (−/⟲/+) บนแผนที่ไม่ต้องการแล้ว

**C1. `app/views/dashboard/_map_grid.html.erb`:** revert กลับเป็นโครงเดิม (ไม่มี wrapper/ปุ่ม):
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

**C2. `app/views/council/_map.html.erb`:** revert:
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

**C3. ลบ `app/javascript/controllers/map_zoom_controller.js`** (ทั้งไฟล์)

**C4. `application.css`:** ลบ block `.map-zoom*` (ตั้งแต่คอมเมนต์ "ซูมเฉพาะแผนที่ (map-zoom controller)" ถึงก่อน `@media(max-width:640px)`) + ลบบรรทัด `.map-zoom-ctl{display:flex}` ใน media query mobile. **คงไว้:** mobile `.tile span` (ชื่อเขตตัวเล็ก option B) + `.map-grid`/`.tile` ปกติ

**Verify:** `get "/"` และ `/council` → body **ไม่มี** `"map-zoom"`; ยังมี `.map-grid` + tiles ครบ; suite เดิมเขียว

## 4. Verification รวม
1. timezone: travel_to UTC 00:35 → header "07:35"; deploy แล้วเปิดดูเวลา +7
2. ข่าว: thumb แสดง (โหลดรูปตรงจาก dailynews CDN), og ล้ม → text อย่างเดียว
3. แผนที่: ไม่มีปุ่ม zoom, ชื่อเขตตัวเล็กยังอยู่, แตะเขตยังเปิด detail
4. suite เดิม (115) + tests ใหม่เขียว
