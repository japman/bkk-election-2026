# Election-night Readiness — Edge-first Caching, Live Council, Capacity

**Date:** 2026-06-25
**Status:** Design — pending user review
**Topic:** ทำให้เว็บประกาศผลเลือกตั้ง กทม. 2569 รับโหลดคืนนับคะแนนได้ โดยดันภาระไป edge, ทำหน้า สก ให้ live, และมี kill-switch กันคอขวด WebSocket

---

## 1. เป้าหมาย & บริบท

ผู้ใช้ต้องการ (เลือกครบทุกข้อ):
1. รับ traffic คืนนับคะแนน (burst เปิดหน้าพร้อมกันเป็นพัน–หมื่น)
2. ทำหน้า สก (`/council`) ให้ live (ปัจจุบันนิ่งจน reload)
3. ลดภาระ/ค่าใช้จ่าย origin server
4. เข้าใจสถานะ architecture ปัจจุบัน (เสร็จแล้ว — ดู §2)

### ข้อจำกัด host
- Origin = **1 host (159.138.241.201, Huawei) 2 vCPU / 4 GB** แชร์กับ Postgres 17 + Redis 7 (accessories ของ Kamal บนเครื่องเดียวกัน)
- **scale ขึ้นได้เฉพาะวันเลือกตั้ง** → ออกแบบให้ภาระ read ไม่ผูกกับสเปก origin
- Cloudflare (Full-strict + Origin Cert) อยู่หน้า → kamal-proxy terminate TLS → Rails

## 2. สถานะปัจจุบัน (ผลการ audit — ข้อเท็จจริงที่ใช้ออกแบบ)

**Hotwire/live updates**
- หน้าผู้ว่าฯ `/` subscribe `turbo_stream_from "results"` (WebSocket `/cable`, ActionCable adapter = **redis**). ทุก 30 วิ `IngestPollJob` (`app/jobs/ingest_poll_job.rb:48`) ถ้าคะแนนเปลี่ยน → `ResultsBroadcaster` (`app/services/results_broadcaster.rb:17`) `broadcast_replace_to "results"` 4 target: `header-status`, `leaderboard`, `zone-map`, `overview-stats`
- safety net: `app/javascript/controllers/fallback_controller.js` — poll `${cdnBase()}/results.json` ทุก 10 วิ เมื่อไม่มี stream เกิน 15 วิ; patch `[data-live]` + tile `--c` (ไม่ replace DOM)
- หน้า สก `/council` — **ไม่มี `turbo_stream_from`** เลย; `council_controller.js` fetch `results-council.json` เฉพาะตอนคลิกเขต → ไม่ auto-update
- zone_detail / trend_chart fetch CDN JSON ตอนใช้งาน (ไม่แตะ origin)

**WebSocket หลัง Cloudflare — พิสูจน์แล้วว่าใช้ได้**
- `curl` WS upgrade `/cable` ด้วย Origin จริง `https://bkk-election-2026.dailynews.co.th` → **HTTP 101 Switching Protocols**
- ด้วย Origin `https://election.dailynews.co.th` (default ใน `production.rb:83`) → **404** (ปฏิเสธ) → ยืนยันว่า `PUBLIC_ORIGIN` ตั้งถูกเป็นโดเมนจริง, `allowed_request_origins` ทำงานถูก

**Caching (ผ่าน Cloudflare จริง)**
- `/assets/*` (Propshaft digested) → **CF HIT**, `public, max-age=1ปี` ✓ (ดีอยู่แล้ว)
- snapshot JSON อยู่ CloudFront แยก (`SNAPSHOT_CDN_URL`), `max-age=5` (`snapshot_publisher.rb:18`) ✓
- `/` (HTML) → `cache-control: private, max-age=60` → **CF MISS** (ไม่ cache)
- `/council` (HTML) → ตั้ง **session cookie** `_..._session` → **CF DYNAMIC** (ไม่ cache)

**สาเหตุ session cookie:** auth (`app/controllers/concerns/authentication.rb`) ใช้ `cookies.signed[:session_id]` (signed cookie คนละตัว, แค่ **อ่าน**) → ไม่ใช่ตัวที่ set. cookie `_..._session` มาจาก `csrf_meta_tags` (`layouts/application.html.erb:9` → `form_authenticity_token` → เขียน `session[:_csrf_token]`). หน้า public read-only ไม่มี form → **ปลด csrf meta ได้ ไม่กระทบ login**

**Capacity ปัจจุบัน**
- Puma: `RAILS_MAX_THREADS` default **3**, `WEB_CONCURRENCY` ไม่ตั้ง → **1 worker × 3 threads** (`config/puma.rb:28`)
- Solid Queue รันใน Puma เดียวกัน (`SOLID_QUEUE_IN_PUMA=1`, `deploy.yml:28`)
- DB pool = `RAILS_MAX_THREADS` default 5 (`database.yml:20`); primary + cache + queue databases บน Postgres ตัวเดียว
- ผล: dynamic request พร้อมกัน ~3; burst เปิดหน้าใหม่ = คอขวด ~37 HTML/วิ; WS = O(N) connection ต่อผู้ชม

## 3. กลยุทธ์รวม — "Edge-first"

บน 2 vCPU/4GB scale origin แทบไม่ได้ → ทำให้ **ทุกการ read มาจาก edge** (Cloudflare cache HTML + CloudFront ส่ง JSON) เพื่อให้ภาระ origin เป็น **O(1)** ไม่ขึ้นกับจำนวนผู้ชม. WebSocket (O(N)) เก็บไว้เป็นของแถมพร้อม kill-switch.

| สถานการณ์ | ตอนนี้ | หลังทำ |
|---|---|---|
| เปิดหน้าใหม่พร้อมกัน | คอขวด 3 threads | origin render ~1 ครั้ง/5วิ (CF เสิร์ฟที่เหลือ) |
| อ่านคะแนนต่อเนื่อง | CDN อยู่แล้ว ✓ | คงเดิม |
| คอขวดที่เหลือ | — | จำนวน WS (governor) → มี kill-switch |

ส่งมอบเป็น 4 component อิสระ (A ก่อน = เลเวอเรจสูงสุด):

---

## 4. Component A — Edge-cache public HTML (`/`, `/council`)

**เป้า:** ให้ Cloudflare cache HTML 2 หน้านี้ ~5 วิ → ดูดซับ burst + ลดภาระ origin

### A1. หยุด set session cookie บนหน้า public
- ใน `app/views/layouts/application.html.erb` (บรรทัด 9) เปลี่ยน `<%= csrf_meta_tags %>` เป็น:
  ```erb
  <%= csrf_meta_tags unless @no_session %>
  ```
- `app/controllers/dashboard_controller.rb#show` และ `council_controller.rb#show`: เพิ่ม `@no_session = true`
- เพียงพอเพราะ 2 action นี้ไม่มี session write อื่น (set แค่ `@election` + `@no_session`); auth อ่าน `cookies.signed[:session_id]` แยก ไม่เขียน session store → ไม่มี `Set-Cookie`
- เหตุผล: auth ใช้ `cookies.signed[:session_id]` แยก → การไม่ render csrf meta ไม่กระทบ login/admin (admin/login เป็นคนละ controller, ยังได้ csrf ปกติ)

### A2. ส่ง cache header ที่ cache ได้
- ใน 2 action เดียวกัน เพิ่ม:
  ```ruby
  expires_in 5.seconds, public: true, "stale-while-revalidate": 30
  ```
  คาดหวัง header: `Cache-Control: public, max-age=5, stale-while-revalidate=30`, ไม่มี `Set-Cookie`
- **ความเสี่ยง:** `stale_when_importmap_changes` (`application_controller.rb:7`) อาจ set ETag/`private`. ถ้า header สุดท้ายไม่เป็น `public` → ใน 2 action นี้ override ด้วยการ set `response.headers["Cache-Control"]` ใน `after_action` หรือข้าม importmap-stale เฉพาะ action นี้ (ผลกระทบของการข้าม = แค่ HTML cached ไม่ผูก etag กับ importmap digest; CF TTL 5วิ จัดการ freshness หลัง deploy อยู่แล้ว)
- **เกณฑ์ผ่าน:** `curl -sI https://bkk-election-2026.dailynews.co.th/` และ `/council` → `cache-control: public, max-age=5...`, **ไม่มี** `set-cookie`

### A3. Cloudflare Cache Rule (ตั้งใน CF dashboard)
Cloudflare ไม่ cache `text/html` เองแม้ header เป็น public → ต้องมี Cache Rule:
- **Rule "Cache public pages":** เงื่อนไข `(http.request.uri.path eq "/") or (http.request.uri.path eq "/council")`
  - Cache eligibility: **Eligible for cache**
  - Edge TTL: **Respect origin** (origin ส่ง max-age=5 แล้ว) หรือ Override = 5s
  - Browser TTL: Respect origin
- **Rule "Bypass dynamic" (ลำดับก่อนหน้า):** เงื่อนไข path เริ่มด้วย `/admin`, `/session`, `/cable`, `/up`, หรือ มี cookie `session_id` (admin ที่ login) → **Bypass cache**
- **ตั้งเองใน CF dashboard (manual)** — plan จะให้ตารางค่าเป๊ะทุกช่อง (path, eligibility, TTL, bypass) ไว้กรอก ไม่ใช้ CF API
- **เกณฑ์ผ่าน:** `curl -sI .../` ครั้งที่ 2 → `cf-cache-status: HIT`; `/admin` → `DYNAMIC`

### A4. ผลที่ได้
origin render `/` + `/council` แค่ ~1 ครั้ง/5วิ ไม่ว่าผู้ชมกี่พัน → burst หาย

---

## 5. Component B — หน้า สก live ด้วย CDN poll

**เป้า:** `/council` อัปเดตเองโดยไม่แตะ origin (อ่านจาก CloudFront ล้วน)

### B1. รวม logic "สรุปที่นั่ง" ให้เป็นแหล่งเดียว (DRY) + แก้สีอิสระให้ตรงกัน
ปัจจุบันมี 2 จุดคำนวณที่นั่ง ไม่ตรงกัน:
- `app/views/council/_seats.html.erb`: group by party, สีเทา `#888888` เมื่อหลายสี (อิสระ)
- `app/services/results_snapshot.rb:49-52`: group by party, **สี = `ws.first[:color]`** (ไม่เทา)

แก้: เพิ่ม method เดียวใช้ร่วม เช่น `Election#council_seat_breakdown` → คืน `[{ party:, color:, seats: }]` (merge by party, เทาเมื่อหลายสี, sort by seats desc)
```ruby
# app/models/election.rb
def council_seat_breakdown
  winners = zones.includes(vote_results: :candidate)
                 .filter_map { |z| z.vote_results.max_by(&:votes)&.candidate }
  winners.group_by(&:party).map do |party, cands|
    colors = cands.map(&:color).uniq
    { party: party, color: (colors.size == 1 ? colors.first : "#888888"), seats: cands.size }
  end.sort_by { |s| -s[:seats] }
end
```
- `_seats.html.erb` และ `results_snapshot.rb#council_json` (`seats:`) เรียก method นี้ → server-render = JSON = JS-render ตรงกันเป๊ะ

### B2. JS poller บนหน้า สก
- เพิ่ม poll ใน `app/javascript/controllers/council_controller.js` (หรือ controller ใหม่ `council_live`) ผูกกับ `.council-layout`:
  - `connect()`: `this.timer = setInterval(() => this.refresh(), 15000)`; เรียก `refresh()` ครั้งแรกเลย (จะได้ค่าล่าสุดถ้า HTML มาจาก edge cache ที่ stale ได้ ≤5วิ)
  - `disconnect()`: `clearInterval(this.timer)`
  - `refresh()`: `fetch(`${cdnBase()}/results-council.json`)` (ใช้ HTTP cache ปกติ ไม่ใส่ no-store → ให้ CloudFront/บราว์เซอร์ cache 5วิ ช่วยลด origin); แล้ว
    - แต่ละ `district`: `document.querySelector(`.tile[data-zone-code="${d.code}"]`)?.style.setProperty('--c', d.winner.color)`
    - rebuild `#council-seats` innerHTML จาก `data.seats` (party-name + count + swatch color)
    - patch `[data-live="counted-pct"]` = `data.counted_percent%`, `[data-live="updated-at"]` = เวลา (header สก ใช้ `header_status` ที่มี data-live เหล่านี้)
- **เกณฑ์ผ่าน:** เปลี่ยนคะแนน สก (admin/console) → ภายใน ~15วิ ไทล์เปลี่ยนสี + จำนวนที่นั่งอัปเดต โดยไม่ reload; Network tab เห็น request ไป CloudFront ไม่ใช่ origin

### B3. ทำไม poll ไม่ใช่ WS
สก ไม่ต้อง instant (คะแนนเปลี่ยนทุก 30วิ) และ poll = ภาระ origin 0 (CloudFront cache 5วิ → origin ~1 req/5วิ ไม่ว่าผู้ชมกี่คน) → เข้ากับเป้า offload

---

## 6. Component C — Governor hybrid + kill-switch (flip สดผ่าน admin)

**เป้า:** ปกติ WS (สดทันที); peak กดปิด WS จากหน้า admin ได้ทันทีโดยไม่ต้อง restart → ทุกคนตกไป CDN poll (ไม่จำกัดคน)

### C1. ที่เก็บ setting แบบ persist (ไม่ใช้ ENV, ไม่ใช้ cache ที่ evict ได้)
ใช้ DB row จริง (กันหาย/กัน evict ตอน peak ซึ่งเป็นช่วงที่พึ่งมันที่สุด):
- migration: `create_table :settings do |t| t.string :key, null: false; t.string :value; t.timestamps end` + unique index บน `key`
- `app/models/setting.rb`:
  ```ruby
  class Setting < ApplicationRecord
    def self.get(k)        = find_by(key: k)&.value
    def self.set(k, v)     = find_or_initialize_by(key: k).update!(value: v.to_s)
    def self.streaming_enabled? = get("live_streaming") != "false"   # default = เปิด (WS)
  end
  ```

### C2. ปุ่ม toggle ในหน้า admin
- route (ใน `namespace :admin`): `post "live_streaming/toggle" => "settings#toggle_streaming"` (หรือเพิ่มใน controller admin ที่มีอยู่)
- `Admin::SettingsController#toggle_streaming` (authenticated, CSRF ปกติ): `Setting.set("live_streaming", !Setting.streaming_enabled?)` → redirect กลับ admin dashboard พร้อม flash
- ใน `app/views/admin/dashboard/index.html.erb`: แสดงสถานะ + ปุ่ม
  > "Live WS: **ON** — [ปิด WS (โหมด peak)]" / "Live WS: **OFF** — [เปิด WS]"

### C3. View gate
- `app/views/dashboard/show.html.erb`:
  ```erb
  <% if Setting.streaming_enabled? %>
    <%= turbo_stream_from "results" %>
  <% end %>
  ```
  และเมื่อปิด → ให้ fallback poll ทันที (ไม่รอ 15วิ): set `data-fallback-stale-after-value="0"` บน `data-controller="live-flash fallback"` เมื่อ `!Setting.streaming_enabled?`
- fallback poller (มีอยู่แล้ว, poll `results.json` ผ่าน CDN) รับช่วงอัตโนมัติ

### C4. ปฏิสัมพันธ์กับ edge-cache (A)
- HTML governor ถูก cache 5วิ → ค่า `streaming_enabled?` ถูก bake ใน HTML ที่ cache → การ flip จะถึง visitor ที่โหลดใหม่ภายใน **~5วิ** (ไม่ต้อง purge CF; edge TTL พาไปเอง). client ที่โหลดค้างอยู่จะเปลี่ยนเมื่อ reload
- query `Setting` 1 ครั้งต่อ render; edge-cache จำกัด render เหลือ ~1/5วิ → ภาระ DB แทบ 0

### C5. เกณฑ์ผ่าน
กดปิดใน admin → ภายใน ~5วิ โหลด `/` ใหม่ไม่มี WS ไป `/cable` (DevTools), คะแนนยังอัปเดตผ่าน poll; กดเปิด → WS กลับมา

---

## 7. Component D — Capacity / election-day runbook

**ปกติ (2 vCPU/4GB):** คง **1 worker × 3 threads** — เพิ่ม worker ไม่คุ้มเพราะแย่ง CPU กับ PG/Redis. หลังทำ A+B origin แทบว่างอยู่แล้ว

**วันเลือกตั้ง (scale host):**
1. scale Huawei instance → **≥ 4 vCPU / 8 GB** (หรือ 8 vCPU ถ้าคาดหมื่น+ และเปิด WS)
2. ตั้ง `WEB_CONCURRENCY=2` (4 vCPU) หรือ `3` (8 vCPU), คง `RAILS_MAX_THREADS=3`
3. ตรวจ Postgres `max_connections` ≥ `WEB_CONCURRENCY × RAILS_MAX_THREADS + solid_queue pool + cache/cable` (default 100 พอ); DB pool ตาม `RAILS_MAX_THREADS`
4. (ถ้าเปิด WS ตอน peak) เฝ้า RAM/connection; ถ้าตึง → เปิด kill-switch (Component C)
5. ตรวจ `cf-cache-status: HIT` บน `/`, `/council` ก่อนเวลาพีค

**ไม่อยู่ใน scope:** แยก Solid Queue ออกจาก Puma เป็น process/container แยก (ทำได้ภายหลังถ้า ingest แย่ง CPU จริง)

---

## 8. ลำดับ & ความเป็นอิสระ
- **A** (edge-cache) — เลเวอเรจสูงสุด, ทำก่อน. โค้ดน้อย (2 controller + layout) + CF rule
- **B** (council live) — อิสระจาก A; DRY seat logic + JS poller
- **C** (kill-switch) — อิสระ; Setting model + migration + admin toggle + view gate
- **D** — เอกสาร/ops, ไม่มีโค้ดนอกจาก env วันงาน

ทุก component ทดสอบ/ship แยกกันได้

## 9. Verification (รวม)
1. `curl -sI .../` + `/council` → `cache-control: public, max-age=5`, ไม่มี `set-cookie`; ครั้งที่ 2 → `cf-cache-status: HIT`
2. `curl -sI .../admin` → ไม่ HIT (bypass)
3. WS ยัง 101 (governor ปกติ); กดปิดใน admin → ภายใน ~5วิ โหลดใหม่ไม่มี `/cable`; กดเปิด → กลับมา
4. แก้คะแนน สก → ไทล์+ที่นั่งอัปเดตใน ~15วิ ไม่ reload, request ไป CloudFront
5. seat: server-render = JSON `seats` = JS-render (อิสระรวมก้อนเดียว สีเทา)
6. โหลดทดสอบ (เช่น `oha`/`k6`) ยิง `/` หลายพัน rps → origin CPU แทบไม่ขึ้น (CF เสิร์ฟ), `/results.json` ผ่าน CloudFront
