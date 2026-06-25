# Election-night Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ทำให้เว็บประกาศผลเลือกตั้ง กทม. 2569 รับโหลดคืนนับคะแนนบน host 2 vCPU/4GB ได้ โดยดันภาระ read ไป edge, ทำหน้า สก ให้ live, และมี kill-switch ปิด WebSocket จาก admin

**Architecture:** Edge-first — Cloudflare cache HTML `/`+`/council` ~5วิ (origin render ~1/5วิ ไม่ว่ากี่พันคน), หน้า สก อัปเดตเองด้วยการ poll snapshot JSON จาก CloudFront (ภาระ origin 0), และ governor WebSocket เปิด/ปิดสดผ่าน `Setting` (DB) ที่กดจากหน้า admin

**Tech Stack:** Rails 8.1, Hotwire/Turbo (ActionCable redis adapter), Stimulus, Propshaft, Solid Queue/Cache, Postgres 17, Redis 7, Kamal 2 + Cloudflare (Full-strict). Tests: **RSpec** (`rspec-rails ~>8.0`) + webmock. **ไม่มี JS test runner** → โค้ด JS verify ด้วยมือ (DevTools/curl)

## Global Constraints

- Host = 1 เครื่อง 2 vCPU/4GB แชร์ web+Postgres+Redis; scale ได้เฉพาะวันเลือกตั้ง → ภาระ read ต้องไม่ผูกกับสเปก origin
- spec อ้างอิง: `docs/superpowers/specs/2026-06-25-election-night-readiness-design.md`
- Cache TTL หน้า public = **5 วินาที** (`max-age=5, public, stale-while-revalidate=30`)
- หน้า public (`/`, `/council`) **ต้องไม่มี `Set-Cookie` session** และไม่ render CSRF meta (auth ใช้ `cookies.signed[:session_id]` แยก ไม่กระทบ login)
- Council poll interval = **15000 ms**; อ่าน `${cdnBase()}/results-council.json` ผ่าน CloudFront (ไม่ใส่ `cache: "no-store"` เพื่อให้ edge/บราว์เซอร์ cache ช่วยลด origin)
- สรุปที่นั่ง สก: รวมตาม **ชื่อพรรค**; พรรคที่มีหลายสี (อิสระ) ใช้ swatch **`#888888`**; เรียงตามจำนวนที่นั่ง desc
- Kill-switch เก็บใน **DB (`Setting`)** ไม่ใช่ ENV/cache; key `"live_streaming"`, **default = เปิด (WS)**; flip ถึง visitor ใหม่ภายใน ~5วิ (edge TTL) — ไม่ purge CF
- Cloudflare Cache Rule = **ตั้งเองใน dashboard (manual)**, ไม่ใช้ CF API
- การ broadcast governor (turbo_stream) ต้องห่อด้วย `Setting.streaming_enabled?`; เมื่อปิด → fallback poller (มีอยู่) poll ทันที (`data-fallback-stale-after-value="0"`)
- ทุก task: ของเดิมต้อง green — รัน `bundle exec rspec` ผ่านก่อน commit

**ลำดับ & ความอิสระ:** Task 1 (A) → Task 2,3 (B) → Task 4,5 (C) → Task 6 (runbook). แต่ละ component ship แยกได้ (A อิสระ; B อิสระ; C: Task 5 ต้องมาหลัง Task 4)

---

### Task 1: Edge-cacheable public HTML (`/`, `/council`)

ทำให้ origin ส่ง header ที่ Cloudflare cache ได้ + เลิก set session cookie บนหน้า public

**Files:**
- Modify: `app/controllers/dashboard_controller.rb`
- Modify: `app/controllers/council_controller.rb`
- Modify: `app/views/layouts/application.html.erb:9`
- Test: `spec/requests/public_caching_spec.rb` (create)

**Interfaces:**
- Consumes: `Election.current`, `Election.council` (มีอยู่), `ElectionSetup#build_election` (spec helper)
- Produces: instance var `@no_session` (truthy บน 2 action นี้) ที่ layout ใช้ตัดสิน csrf meta

- [ ] **Step 1: Write the failing test**

สร้าง `spec/requests/public_caching_spec.rb`:
```ruby
require "rails_helper"

RSpec.describe "Public page edge-caching", type: :request do
  include ElectionSetup
  before { allow(News::Fetcher).to receive(:latest).and_return([]) }

  shared_examples "an edge-cacheable public page" do |path|
    it "sends public short-lived Cache-Control + no session cookie (#{path})" do
      get path
      cc = response.headers["Cache-Control"].to_s
      expect(cc).to include("public")
      expect(cc).to include("max-age=5")
      expect(response.headers["Set-Cookie"].to_s).not_to include("_dailynews_election_bkk2026_session")
    end

    it "omits the CSRF meta tag (#{path})" do
      get path
      expect(response.body).not_to include('name="csrf-token"')
    end
  end

  context "governor /" do
    before { build_election(zones: 1, candidates: 1) }
    include_examples "an edge-cacheable public page", "/"
  end

  context "council /council" do
    before { Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council") }
    include_examples "an edge-cacheable public page", "/council"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/public_caching_spec.rb`
Expected: FAIL — Cache-Control ไม่มี "public"/"max-age=5" และ body ยังมี `name="csrf-token"`

- [ ] **Step 3: Implement — controllers set cache header + `@no_session`**

`app/controllers/dashboard_controller.rb`:
```ruby
class DashboardController < ApplicationController
  allow_unauthenticated_access

  def show
    @election = Election.current
    @no_session = true
    expires_in 5.seconds, public: true, "stale-while-revalidate": 30
  end
end
```

`app/controllers/council_controller.rb`:
```ruby
class CouncilController < ApplicationController
  allow_unauthenticated_access

  def show
    @election = Election.council
    @no_session = true
    expires_in 5.seconds, public: true, "stale-while-revalidate": 30
  end
end
```

- [ ] **Step 4: Implement — layout skips CSRF meta on public pages**

`app/views/layouts/application.html.erb` บรรทัด 9 เปลี่ยนจาก `<%= csrf_meta_tags %>` เป็น:
```erb
    <%= csrf_meta_tags unless @no_session %>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/requests/public_caching_spec.rb spec/requests/dashboard_spec.rb spec/requests/council_spec.rb`
Expected: PASS ทั้งหมด (รวมของเดิม — theme toggle / empty state ยังผ่าน)

- [ ] **Step 6: Commit**

```bash
git add app/controllers/dashboard_controller.rb app/controllers/council_controller.rb app/views/layouts/application.html.erb spec/requests/public_caching_spec.rb
git commit -m "Make public pages edge-cacheable (public max-age=5, no session cookie)"
```

- [ ] **Step 7: Manual — ตั้ง Cloudflare Cache Rule (dashboard, ทำครั้งเดียว)**

หลัง deploy: ตั้ง 2 Cache Rules ที่ **Cloudflare > Caching > Cache Rules** (ลำดับสำคัญ — bypass ต้องอยู่ก่อน):

| ลำดับ | Rule name | When incoming requests match | Then |
|---|---|---|---|
| 1 | Bypass dynamic | `Path starts with /admin` **OR** `/session` **OR** `/cable` **OR** `/up` **OR** `Cookie contains "session_id"` | Cache eligibility: **Bypass cache** |
| 2 | Cache public pages | `URI Path equals "/"` **OR** `URI Path equals "/council"` | Cache eligibility: **Eligible for cache**; Edge TTL: **Use cache-control header if present** (origin ส่ง max-age=5 แล้ว); Browser TTL: Respect origin |

ตรวจ: `curl -sI https://bkk-election-2026.dailynews.co.th/` 2 ครั้ง → ครั้งที่ 2 `cf-cache-status: HIT`; `curl -sI .../admin` → `DYNAMIC`/bypass

---

### Task 2: DRY seat breakdown + merge independents (server + snapshot + partial)

แหล่งคำนวณที่นั่งเดียว ใช้ทั้ง view, snapshot JSON, และ JS (Task 3) — อิสระรวมเป็นก้อนเดียว สีเทาเมื่อหลายสี

**Files:**
- Modify: `app/models/election.rb` (เพิ่ม `#council_seat_breakdown`)
- Modify: `app/services/results_snapshot.rb:49-52`
- Modify: `app/views/council/_seats.html.erb`
- Test: `spec/models/election_spec.rb` (เพิ่ม), `spec/services/results_snapshot_spec.rb` (เพิ่ม), `spec/requests/council_spec.rb` (เพิ่ม)

**Interfaces:**
- Produces: `Election#council_seat_breakdown -> Array<{party: String, color: String, seats: Integer}>` (sorted by seats desc; independents merged; color `#888888` เมื่อหลายสี) — ใช้โดย Task 3 (JS อ่านจาก `results-council.json` key `seats` ที่มี shape เดียวกัน)
- Consumes: `ResultWriter.new(zone, source:).apply!({number => votes})` (spec helper สร้าง vote_results), `ResultsSnapshot.new(election).as_json`

- [ ] **Step 1: Write the failing test (model)**

เพิ่มใน `spec/models/election_spec.rb`:
```ruby
  describe "#council_seat_breakdown" do
    it "merges same-party winners and greys multi-colour parties (อิสระ)" do
      e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
      e.candidates.create!(number: 1, name: "A", party: "อิสระ", color: "#aa0000")
      e.candidates.create!(number: 2, name: "B", party: "อิสระ", color: "#00aa00")
      e.candidates.create!(number: 3, name: "C", party: "พรรคก", color: "#0000aa")
      z1 = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
      z2 = e.zones.create!(code: "02", name: "z2", grid_col: 2, grid_row: 1)
      z3 = e.zones.create!(code: "03", name: "z3", grid_col: 3, grid_row: 1)
      ResultWriter.new(z1, source: "api").apply!({ 1 => 10 })
      ResultWriter.new(z2, source: "api").apply!({ 2 => 10 })
      ResultWriter.new(z3, source: "api").apply!({ 3 => 10 })

      rows = e.council_seat_breakdown
      ind = rows.find { |r| r[:party] == "อิสระ" }
      expect(ind[:seats]).to eq(2)
      expect(ind[:color]).to eq("#888888")
      expect(rows.find { |r| r[:party] == "พรรคก" }[:color]).to eq("#0000aa")
      expect(rows.first[:seats]).to be >= rows.last[:seats] # sorted desc
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/election_spec.rb -e council_seat_breakdown`
Expected: FAIL — `NoMethodError: undefined method 'council_seat_breakdown'`

- [ ] **Step 3: Implement the method**

เพิ่มใน `app/models/election.rb` (ก่อน `end` ของ class):
```ruby
  # สรุปที่นั่ง สก: รวมตามชื่อพรรค (อิสระหลายเบอร์รวมก้อนเดียว), สีเทาเมื่อหลายสี
  def council_seat_breakdown
    winners = zones.includes(vote_results: :candidate)
                   .filter_map { |z| z.vote_results.max_by(&:votes)&.candidate }
    winners.group_by(&:party).map do |party, cands|
      colors = cands.map(&:color).uniq
      { party: party, color: (colors.size == 1 ? colors.first : "#888888"), seats: cands.size }
    end.sort_by { |s| -s[:seats] }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/election_spec.rb -e council_seat_breakdown`
Expected: PASS

- [ ] **Step 5: Write failing test (snapshot uses the breakdown)**

เพิ่มใน `spec/services/results_snapshot_spec.rb`:
```ruby
  it "council seats merge independents and grey multi-colour parties" do
    e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    e.candidates.create!(number: 1, name: "A", party: "อิสระ", color: "#aa0000")
    e.candidates.create!(number: 2, name: "B", party: "อิสระ", color: "#00aa00")
    z1 = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "z2", grid_col: 2, grid_row: 1)
    ResultWriter.new(z1, source: "api").apply!({ 1 => 10 })
    ResultWriter.new(z2, source: "api").apply!({ 2 => 10 })

    seats = ResultsSnapshot.new(e).as_json[:seats]
    ind = seats.find { |s| s[:party] == "อิสระ" }
    expect(ind[:seats]).to eq(2)
    expect(ind[:color]).to eq("#888888")
  end
```

- [ ] **Step 6: Run to verify it fails**

Run: `bundle exec rspec spec/services/results_snapshot_spec.rb -e "merge independents"`
Expected: FAIL — สีเป็น `#aa0000` (ของเดิม `ws.first[:color]`) ไม่ใช่ `#888888`

- [ ] **Step 7: Implement — snapshot ใช้ breakdown**

`app/services/results_snapshot.rb` แทนบรรทัด 49-52 (การคำนวณ `seats = districts.map ...`) ด้วย:
```ruby
    seats = @election.council_seat_breakdown
```
(ลบ chain `.group_by/.map/.sort_by` เดิมทั้งบล็อก; `districts` ยังคำนวณเหมือนเดิมด้านบน)

- [ ] **Step 8: Implement — partial ใช้ breakdown**

`app/views/council/_seats.html.erb` แทนทั้งไฟล์ด้วย:
```erb
<div class="council-seats" id="council-seats">
  <% election.council_seat_breakdown.each do |row| %>
    <span class="seat-row">
      <i style="background: <%= row[:color] %>"></i>
      <span class="party-name"><%= row[:party] %></span>
      <b><%= row[:seats] %></b><span class="seat-unit">ที่นั่ง</span>
    </span>
  <% end %>
</div>
```

- [ ] **Step 9: Write failing request test (partial renders grey)**

เพิ่มใน `spec/requests/council_spec.rb`:
```ruby
  it "renders a single grey row for merged independents" do
    e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    e.candidates.create!(number: 1, name: "A", party: "อิสระ", color: "#aa0000")
    e.candidates.create!(number: 2, name: "B", party: "อิสระ", color: "#00aa00")
    z1 = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "z2", grid_col: 2, grid_row: 1)
    ResultWriter.new(z1, source: "api").apply!({ 1 => 10 })
    ResultWriter.new(z2, source: "api").apply!({ 2 => 10 })
    get "/council"
    expect(response.body).to include("#888888")
    expect(response.body.scan("party-name").size).to eq(1)
  end
```

- [ ] **Step 10: Run full affected suites to verify pass**

Run: `bundle exec rspec spec/models/election_spec.rb spec/services/results_snapshot_spec.rb spec/requests/council_spec.rb`
Expected: PASS ทั้งหมด

- [ ] **Step 11: Commit**

```bash
git add app/models/election.rb app/services/results_snapshot.rb app/views/council/_seats.html.erb spec/models/election_spec.rb spec/services/results_snapshot_spec.rb spec/requests/council_spec.rb
git commit -m "DRY council seat breakdown; merge independents (grey) across view + snapshot"
```

---

### Task 3: หน้า สก live ด้วย CDN poll (Stimulus)

`council_controller` poll `results-council.json` ทุก 15วิ → repaint สีไทล์ + รายการที่นั่ง + counted%/เวลา (ไม่แตะ origin)

**Files:**
- Modify: `app/javascript/controllers/council_controller.js`

**Interfaces:**
- Consumes: snapshot `results-council.json` (key `districts[].code`, `districts[].winner.color`, `seats[] = {party,color,seats}` จาก Task 2), DOM hooks: `.tile[data-zone-code]`, `#council-seats`, `[data-live="counted-pct"]`, `[data-live="updated-at"]` (มีอยู่จาก site_header)
- Produces: ไม่มี (UI behavior)

> **หมายเหตุ:** ไม่มี JS test runner ในโปรเจกต์ → verify ด้วยมือ (Step 3)

- [ ] **Step 1: Implement — เพิ่ม poller ใน council_controller (เก็บ show/hide เดิมไว้)**

แทนทั้งไฟล์ `app/javascript/controllers/council_controller.js` ด้วย:
```js
import { Controller } from "@hotwired/stimulus"

const cdnBase = () => document.querySelector('meta[name="snapshot-cdn"]')?.content || ""

export default class extends Controller {
  static targets = ["panel", "name", "counted", "rows"]
  static values = { interval: { type: Number, default: 15000 } }

  connect() {
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() { clearInterval(this.timer) }

  // poll สด: repaint แผนที่ + ที่นั่ง + header โดยไม่ reload (ผ่าน CloudFront)
  async refresh() {
    try {
      const res = await fetch(`${cdnBase()}/results-council.json`)
      if (!res.ok) return
      this.repaint(await res.json())
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  repaint(data) {
    (data.districts || []).forEach(d => {
      const tile = document.querySelector(`.tile[data-zone-code="${d.code}"]`)
      if (tile && d.winner) tile.style.setProperty("--c", d.winner.color)
    })
    const seats = document.getElementById("council-seats")
    if (seats && data.seats) {
      seats.innerHTML = data.seats.map(s =>
        `<span class="seat-row"><i style="background:${s.color}"></i>` +
        `<span class="party-name">${s.party}</span>` +
        `<b>${s.seats}</b><span class="seat-unit">ที่นั่ง</span></span>`
      ).join("")
    }
    const set = (key, text) => document.querySelectorAll(`[data-live="${key}"]`).forEach(el => {
      if (el.textContent !== text) el.textContent = text
    })
    if (data.counted_percent != null) set("counted-pct", `${data.counted_percent}%`)
    if (data.updated_at) set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH")} น.`)
  }

  // คลิกเขต → ดึงรายละเอียดผู้สมัครในเขตนั้น (เดิม)
  async show(e) {
    const code = e.currentTarget.dataset.zoneCode
    const res = await fetch(`${cdnBase()}/results-council.json`, { cache: "no-store" })
    if (!res.ok) return
    const data = await res.json()
    const d = (data.districts || []).find(x => x.code === code)
    if (!d) return
    const sum = d.results.reduce((s, r) => s + r.votes, 0)
    this.nameTarget.textContent = `เขต${d.name}`
    this.countedTarget.textContent = `นับแล้ว ${d.counted_percent}%`
    this.rowsTarget.innerHTML = d.results.map((r, i) => {
      const pct = sum === 0 ? 0 : (r.votes * 100 / sum).toFixed(1)
      return `<div class="zd-row ${i === 0 ? "winner" : ""}">
        ${r.photo_url ? `<img class="zd-photo" src="${r.photo_url}" alt="" loading="lazy">` : `<i style="background:${r.color}"></i>`}
        <span class="zd-name">เบอร์ ${r.number} ${r.name} <small>${r.party || ""}</small></span>
        <span class="zd-v num">${r.votes.toLocaleString("th-TH")} (${pct}%)</span>
      </div>`
    }).join("")
    this.panelTarget.classList.add("show")
  }

  hide() { this.panelTarget.classList.remove("show") }
}
```

- [ ] **Step 2: Verify syntax**

Run: `node --check app/javascript/controllers/council_controller.js`
Expected: ไม่มี output (ผ่าน)

- [ ] **Step 3: Manual verification (DevTools, ใน UAT/prod หลัง deploy)**

1. เปิด `/council` → DevTools Network เห็น fetch `results-council.json` ทุก ~15วิ ไป **CloudFront** (ไม่ใช่ origin)
2. แก้คะแนน สก ผ่าน admin/console → ภายใน ~15วิ ไทล์เปลี่ยนสี + รายการที่นั่งอัปเดต + counted% เปลี่ยน **โดยไม่ reload**
3. คลิกเขต → panel รายละเอียดยังทำงาน (regression check)

- [ ] **Step 4: Commit**

```bash
git add app/javascript/controllers/council_controller.js
git commit -m "Council page: live repaint by polling CDN snapshot every 15s"
```

---

### Task 4: `Setting` model + migration (kill-switch storage)

DB row จริง (persist ข้าม restart, ไม่โดน cache evict) เก็บสถานะ live streaming

**Files:**
- Create: `db/migrate/<timestamp>_create_settings.rb` (ผ่าน generator)
- Create: `app/models/setting.rb`
- Test: `spec/models/setting_spec.rb` (create)

**Interfaces:**
- Produces: `Setting.get(key) -> String?`, `Setting.set(key, value) -> Setting`, `Setting.streaming_enabled? -> Boolean` (default true; false เมื่อ value == "false") — ใช้โดย Task 5

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration CreateSettings`
แล้วแทนเนื้อไฟล์ `db/migrate/<timestamp>_create_settings.rb` ด้วย:
```ruby
class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :key, null: false
      t.string :value
      t.timestamps
    end
    add_index :settings, :key, unique: true
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate`
Expected: สร้างตาราง `settings`; `db/schema.rb` อัปเดต

- [ ] **Step 3: Write the failing test**

สร้าง `spec/models/setting_spec.rb`:
```ruby
require "rails_helper"

RSpec.describe Setting do
  it "defaults streaming to enabled when unset" do
    expect(Setting.streaming_enabled?).to be(true)
  end

  it "round-trips get/set and disables streaming" do
    Setting.set("live_streaming", false)
    expect(Setting.get("live_streaming")).to eq("false")
    expect(Setting.streaming_enabled?).to be(false)
  end

  it "re-enables when set back to true" do
    Setting.set("live_streaming", false)
    Setting.set("live_streaming", true)
    expect(Setting.streaming_enabled?).to be(true)
  end
end
```

- [ ] **Step 4: Run to verify it fails**

Run: `bundle exec rspec spec/models/setting_spec.rb`
Expected: FAIL — `uninitialized constant Setting`

- [ ] **Step 5: Implement the model**

สร้าง `app/models/setting.rb`:
```ruby
class Setting < ApplicationRecord
  def self.get(key)
    find_by(key: key)&.value
  end

  def self.set(key, value)
    find_or_initialize_by(key: key).tap { |s| s.update!(value: value.to_s) }
  end

  def self.streaming_enabled?
    get("live_streaming") != "false"
  end
end
```

- [ ] **Step 6: Run to verify it passes**

Run: `bundle exec rspec spec/models/setting_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/setting.rb spec/models/setting_spec.rb
git commit -m "Add Setting model for runtime live-streaming toggle"
```

---

### Task 5: Admin toggle + governor view gate (kill-switch UI)

ปุ่มในหน้า admin เปิด/ปิด WS สด; หน้า `/` แสดง `turbo_stream_from` เฉพาะตอนเปิด, ปิดแล้ว fallback poll ทันที

**Files:**
- Modify: `config/routes.rb:14-21` (namespace :admin)
- Create: `app/controllers/admin/settings_controller.rb`
- Modify: `app/views/admin/dashboard/index.html.erb`
- Modify: `app/views/dashboard/show.html.erb`
- Test: `spec/requests/admin_spec.rb` (เพิ่ม), `spec/requests/dashboard_spec.rb` (เพิ่ม)

**Interfaces:**
- Consumes: `Setting.streaming_enabled?`, `Setting.set` (Task 4); fallback controller value `data-fallback-stale-after-value` (Stimulus controller "fallback", value "staleAfter")
- Produces: route helper `toggle_streaming_admin_path` (PATCH)

- [ ] **Step 1: Write failing admin test**

เพิ่มใน `spec/requests/admin_spec.rb` ภายใน `describe "เมื่อ login แล้ว"` (หลัง `before { sign_in_as(admin) }`):
```ruby
    it "toggles live streaming on and off" do
      expect(Setting.streaming_enabled?).to be(true)
      patch toggle_streaming_admin_path
      expect(Setting.streaming_enabled?).to be(false)
      patch toggle_streaming_admin_path
      expect(Setting.streaming_enabled?).to be(true)
    end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/admin_spec.rb -e "toggles live streaming"`
Expected: FAIL — `undefined local variable or method 'toggle_streaming_admin_path'`

- [ ] **Step 3: Implement route**

`config/routes.rb` ภายใน `namespace :admin do ... end` (หลังบรรทัด `resources :revisions, only: :index`):
```ruby
    patch "settings/streaming", to: "settings#toggle_streaming", as: :toggle_streaming
```

- [ ] **Step 4: Implement controller**

สร้าง `app/controllers/admin/settings_controller.rb`:
```ruby
class Admin::SettingsController < ApplicationController
  # require_authentication อยู่ใน ApplicationController (admin ไม่ได้ allow_unauthenticated_access)
  def toggle_streaming
    Setting.set("live_streaming", !Setting.streaming_enabled?)
    redirect_to admin_root_path,
      notice: "Live WS: #{Setting.streaming_enabled? ? 'เปิด (push สด)' : 'ปิด (โหมด peak — ทุกคน poll CDN)'}"
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/requests/admin_spec.rb -e "toggles live streaming"`
Expected: PASS

- [ ] **Step 6: Write failing dashboard gate test**

เพิ่มใน `spec/requests/dashboard_spec.rb`:
```ruby
  it "subscribes to the results stream when streaming is enabled" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).to include("turbo-cable-stream-source")
  end

  it "drops the stream and polls immediately when streaming is disabled" do
    build_election(zones: 1, candidates: 1)
    Setting.set("live_streaming", false)
    get "/"
    expect(response.body).not_to include("turbo-cable-stream-source")
    expect(response.body).to include('data-fallback-stale-after-value="0"')
  end
```

- [ ] **Step 7: Run to verify it fails**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e streaming`
Expected: FAIL — stream ยังอยู่เสมอ และไม่มี `data-fallback-stale-after-value="0"`

- [ ] **Step 8: Implement governor view gate**

`app/views/dashboard/show.html.erb` แทนทั้งไฟล์ด้วย:
```erb
<% if @election.nil? %>
  <%= render "site_header" %>
  <main class="wrap"><p>ยังไม่เปิดรายงานผล</p></main>
<% else %>
  <% if Setting.streaming_enabled? %>
    <%= turbo_stream_from "results" %>
  <% end %>
  <div data-controller="live-flash fallback"
       data-fallback-stale-after-value="<%= Setting.streaming_enabled? ? 15000 : 0 %>">
    <%= render "site_header", election: @election %>
    <%= render "hero", election: @election %>
    <main class="wrap">
      <%= render "leaderboard", election: @election %>
      <%= render "map", election: @election %>
      <%= render "stats", election: @election %>
      <%= render "news" %>
    </main>
  </div>
  <footer>ผลคะแนนอย่างไม่เป็นทางการ — รวบรวมโดยทีมข่าวเดลินิวส์</footer>
<% end %>
```

- [ ] **Step 9: Run to verify it passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS (รวมของเดิม)

- [ ] **Step 10: Implement admin toggle button**

`app/views/admin/dashboard/index.html.erb` เพิ่ม section ใหม่หลัง section "โหมดข้อมูล" (หลัง `</section>` แรก, ก่อน section "กรอก/แก้คะแนนรายเขต"):
```erb
  <section class="admin-card">
    <div class="mode-line">
      <span>Live WebSocket:</span>
      <span class="mode-pill <%= Setting.streaming_enabled? ? "api" : "manual" %>">
        <span class="dot"></span>
        <%= Setting.streaming_enabled? ? "ON — push สด (ปกติ)" : "OFF — โหมด peak (ทุกคน poll CDN)" %>
      </span>
      <%= button_to Setting.streaming_enabled? ? "ปิด WS (โหมด peak)" : "เปิด WS",
            toggle_streaming_admin_path, method: :patch,
            class: "btn #{Setting.streaming_enabled? ? 'btn-ghost' : 'btn-primary'} btn-sm",
            data: { turbo_confirm: "ยืนยันสลับโหมด Live WS? มีผลกับ visitor ใหม่ภายใน ~5 วิ" } %>
    </div>
  </section>
```

- [ ] **Step 11: Run full suite (regression)**

Run: `bundle exec rspec`
Expected: PASS ทั้งหมด

- [ ] **Step 12: Commit**

```bash
git add config/routes.rb app/controllers/admin/settings_controller.rb app/views/admin/dashboard/index.html.erb app/views/dashboard/show.html.erb spec/requests/admin_spec.rb spec/requests/dashboard_spec.rb
git commit -m "Admin live-WS kill-switch: toggle button + governor turbo_stream gate"
```

---

### Task 6: Election-day runbook (เอกสาร, ไม่มีโค้ด)

**Files:**
- Create: `docs/runbooks/election-night.md`

- [ ] **Step 1: เขียน runbook**

สร้าง `docs/runbooks/election-night.md`:
```markdown
# Election-night Runbook

## ก่อนเริ่มนับคะแนน
- [ ] ยืนยัน Cloudflare Cache Rules ทำงาน: `curl -sI https://bkk-election-2026.dailynews.co.th/` (ครั้งที่ 2 → `cf-cache-status: HIT`), `/admin` → bypass/DYNAMIC
- [ ] ยืนยัน WS: WS upgrade `/cable` (Origin โดเมนจริง) → 101
- [ ] ยืนยันหน้า สก poll: `/council` DevTools เห็น fetch `results-council.json` ทุก 15วิ
- [ ] Admin > Live WebSocket = ON

## Scale host (ก่อนพีค)
1. scale Huawei instance → ≥ 4 vCPU / 8 GB (8 vCPU ถ้าคาดหมื่น+ และเปิด WS)
2. ตั้ง env แล้ว reboot app: `WEB_CONCURRENCY=2` (4 vCPU) หรือ `3` (8 vCPU); คง `RAILS_MAX_THREADS=3`
3. ตรวจ Postgres `max_connections` ≥ WEB_CONCURRENCY × RAILS_MAX_THREADS + queue + cache/cable (default 100 พอ)

## ถ้า origin/RAM ตึงระหว่างพีค
- เข้า Admin > กด "ปิด WS (โหมด peak)" → visitor ใหม่เลิกต่อ WebSocket ภายใน ~5วิ, ทุกคน poll CDN แทน (ภาระ origin O(1))
- กลับมากด "เปิด WS" เมื่อโหลดลด

## หลังจบงาน
- คืนค่า host/WEB_CONCURRENCY; Live WS = ON
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/election-night.md
git commit -m "Add election-night runbook (Cloudflare verify, scaling, kill-switch)"
```

---

## Final Verification (หลังครบทุก task)

- [ ] `bundle exec rspec` — green ทั้งหมด
- [ ] Deploy (`kamal deploy`) แล้ว: `curl -sI .../` + `/council` → `cache-control: public, max-age=5`, ไม่มี `set-cookie`
- [ ] ตั้ง Cloudflare Cache Rule (Task 1 Step 7) → `curl -sI .../` ครั้งที่ 2 → `cf-cache-status: HIT`; `/admin` → bypass
- [ ] WS upgrade `/cable` (Origin จริง) → 101 (governor ปกติ)
- [ ] Admin กด "ปิด WS" → โหลด `/` ใหม่ ภายใน ~5วิ ไม่มี `turbo-cable-stream-source`; กด "เปิด WS" → กลับมา
- [ ] `/council`: แก้คะแนน → ไทล์+ที่นั่ง+counted% อัปเดตใน ~15วิ ไม่ reload; request ไป CloudFront ไม่ใช่ origin
- [ ] อิสระรวมก้อนเดียว สีเทา ตรงกันทั้ง server-render + JSON `seats` + JS repaint

## Self-Review notes (ผู้เขียน plan ตรวจแล้ว)
- **Spec coverage:** A→Task 1, B→Task 2-3, C→Task 4-5, D→Task 6 ครบทุก §
- **Placeholder scan:** ไม่มี TBD; โค้ดเต็มทุก step
- **Type consistency:** `council_seat_breakdown` คืน `{party,color,seats}` ใช้ตรงกันใน partial/snapshot/JS; `Setting.streaming_enabled?` ใช้ตรงกันใน view/admin/controller; `toggle_streaming_admin_path` (PATCH) ตรงกับ route `as: :toggle_streaming`
