# BKK 2026 Election Results Website — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** เว็บรายงานผลเลือกตั้งผู้ว่าฯ กทม. 2569 แบบ realtime — push <5 วิ, รองรับ 6,000 concurrent users, มี admin panel กรอกมือ fallback — พร้อมใช้ 21 มิ.ย. 2026

**Architecture:** Rails 8 monolith เดียว: Ingest job ดึงผลจาก API กกต. ทุก 30 วิ → validate → PostgreSQL → broadcast Turbo Streams ผ่าน ActionCable (Redis pub/sub) ถึง browser; ทุกการเปลี่ยนแปลง publish `results.json` ขึ้น S3/CloudFront เป็น polling fallback เมื่อ WS หลุด Admin panel ใช้ Rails 8 authentication generator + โหมดสลับ api⇄manual

**Tech Stack:** Rails 8.x, PostgreSQL, Redis (ActionCable adapter), Solid Queue (recurring jobs), Hotwire (Turbo Streams + Stimulus), Propshaft + Importmap, RSpec, aws-sdk-s3, k6 (load test)

**Reference docs:**
- Spec: `docs/superpowers/specs/2026-06-12-election-results-design.md`
- Approved UI mockup (v1): `docs/mockups/election-ui-mockup.html` — CSS/markup ของ public site ยกมาจากไฟล์นี้

**ข้อตกลงทั้งแผน:**
- ทุกคำสั่งรันจาก repo root (`dailynews-election-bkk2026/`) — Rails app อยู่ที่ root
- ชื่อผู้สมัคร/คะแนนใน seeds เป็น**ข้อมูลจำลอง** แทนที่ด้วยข้อมูลจริงเมื่อ กกต. ประกาศรายชื่อ
- ค่า `source` ใน VoteResult/ZoneStat = `api|manual`, ใน ResultRevision = `api|admin` (ตาม spec §6)
- **API กกต. ยังไม่ได้ spec จริง** — ทำต่อด้วย format สมมติ (Task 7) ได้เลย
  เมื่อได้ spec จริงค่อยแก้ `Ingest::EctAdapter` + fixture **เท่านั้น** ส่วนอื่นไม่กระทบ

---

## File Structure

```
app/
  models/
    election.rb          # ราก aggregate: enum data_mode, leaderboard, counted_percent, stats_summary
    candidate.rb         # ผู้สมัคร (number unique ต่อ election)
    zone.rb              # 50 เขต + พิกัด tile cartogram (grid_col/grid_row), leading_candidate
    vote_result.rb       # คะแนนต่อ (zone, candidate) — unique คู่
    zone_stat.rb         # สถิติรายเขต (ผู้มาใช้สิทธิ/บัตรเสีย/นับแล้ว%)
    result_revision.rb   # audit log ทุกการแก้ (polymorphic → VoteResult/ZoneStat)
  services/
    result_writer.rb     # จุดเดียวที่เขียนคะแนน: validate ไม่ลดลง + สร้าง revision
    results_snapshot.rb  # สร้าง payload results.json
    snapshot_publisher.rb# เขียน results.json → public/ (dev) หรือ S3 (prod)
    results_broadcaster.rb # broadcast Turbo Streams 4 regions
    ingest/ect_adapter.rb  # จุดเดียวที่ผูก format API กกต. (spec §9)
    ingest/client.rb       # HTTP fetch (แยกไว้ให้ stub ง่าย)
    news/fetcher.rb        # RSS dailynews + cache 5 นาที
  jobs/ingest_poll_job.rb
  controllers/
    dashboard_controller.rb
    admin/dashboard_controller.rb, admin/zone_results_controller.rb,
    admin/elections_controller.rb, admin/revisions_controller.rb
  views/dashboard/  # show + _site_header, _header_status, _hero, _leaderboard, _map, _stats, _news
  views/admin/      # dashboard/index, zone_results/edit, revisions/index
  javascript/controllers/
    live_flash_controller.js   # flash ตัวเลขที่เปลี่ยน
    trend_chart_controller.js  # กราฟคะแนนสะสม (poll results.json)
    zone_detail_controller.js  # คลิกเขต → คะแนน top 3
    fallback_controller.js     # WS เงียบ >15 วิ → poll results.json
config/recurring.yml  # IngestPollJob ทุก 30 วิ
db/seeds.rb           # 50 เขต (พิกัดจาก mockup) + ผู้สมัครจำลอง
loadtest/ws.js, loadtest/poll.js
docs/runbook-election-night.md
spec/ ...             # ตามโครง app + fixtures
```

---

## Phase 1 — Foundation

### Task 1: Rails 8 app scaffold + RSpec

**Files:**
- Create: Rails app ทั้งโครงที่ repo root (via `rails new`)
- Create: `spec/support/election_setup.rb`
- Modify: `Gemfile`, `spec/rails_helper.rb`

- [ ] **Step 1: ตรวจ environment**

```bash
ruby -v          # ต้อง >= 3.3
psql --version   # ต้องมี PostgreSQL
redis-cli ping   # ต้องตอบ PONG
gem list rails   # ถ้าไม่มี rails 8: gem install rails
```

- [ ] **Step 2: สร้าง Rails app ทับ repo เดิม**

```bash
rails new . --database=postgresql --skip-test --skip-kamal --force
```

`--force` จะ overwrite `README.md`/`.gitignore` เดิม (มีแค่ 1 บรรทัด ไม่เป็นไร) — `docs/` ไม่ถูกแตะ
ตรวจว่า `git status` เห็นไฟล์ Rails ใหม่ และ `docs/` ยังอยู่ครบ

- [ ] **Step 3: ติดตั้ง RSpec + redis gem**

```bash
bundle add rspec-rails --group "development,test"
bundle add redis
bin/rails generate rspec:install
```

Expected: สร้าง `spec/spec_helper.rb`, `spec/rails_helper.rb`, `.rspec`

- [ ] **Step 4: เปิด support dir ใน `spec/rails_helper.rb`**

หา comment บรรทัด `Dir[Rails.root.join('spec', 'support', ...)]` แล้ว uncomment:

```ruby
Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }
```

- [ ] **Step 5: สร้าง test helper สำหรับ setup election**

Create `spec/support/election_setup.rb`:

```ruby
module ElectionSetup
  # สร้าง election พร้อม candidates/zones ขั้นต่ำสำหรับ spec
  def build_election(zones: 2, candidates: 2)
    election = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28), status: "live")
    candidates.times do |i|
      election.candidates.create!(number: i + 1, name: "ผู้สมัคร #{i + 1}", party: "พรรค #{i + 1}", color: "#0E8A45")
    end
    zones.times do |i|
      election.zones.create!(code: format("%02d", i + 1), name: "เขต #{i + 1}", grid_col: i + 1, grid_row: 1)
    end
    election
  end
end

RSpec.configure { |config| config.include ElectionSetup }
```

(จะ require Election ตอนรันเท่านั้น — สร้างไฟล์นี้ก่อน model ได้)

- [ ] **Step 6: เตรียม database และตรวจ boot**

```bash
bin/rails db:prepare
bin/rails runner 'puts Rails.version'   # Expected: 8.x.x
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: scaffold Rails 8 app with PostgreSQL, RSpec, redis"
```

---

### Task 2: Core models — Election, Candidate, Zone

**Files:**
- Test: `spec/models/core_models_spec.rb`
- Create: migrations + `app/models/election.rb`, `app/models/candidate.rb`, `app/models/zone.rb`

- [ ] **Step 1: เขียน failing spec**

Create `spec/models/core_models_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Election do
  it "requires name and election_date" do
    expect(Election.new).not_to be_valid
  end

  it "defaults data_mode to api" do
    e = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28))
    expect(e).to be_api
  end

  it "returns the newest election as current" do
    Election.create!(name: "เก่า", election_date: Date.new(2022, 5, 22))
    new_e = Election.create!(name: "ใหม่", election_date: Date.new(2026, 6, 28))
    expect(Election.current).to eq(new_e)
  end
end

RSpec.describe Candidate do
  it "enforces unique number per election" do
    e = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28))
    e.candidates.create!(number: 1, name: "ก", color: "#000000")
    expect(e.candidates.build(number: 1, name: "ข", color: "#111111")).not_to be_valid
  end
end

RSpec.describe Zone do
  it "enforces unique code per election" do
    e = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28))
    e.zones.create!(code: "01", name: "พระนคร", grid_col: 5, grid_row: 5)
    expect(e.zones.build(code: "01", name: "ดุสิต", grid_col: 5, grid_row: 4)).not_to be_valid
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/models/core_models_spec.rb
```

Expected: FAIL — `uninitialized constant Election`

- [ ] **Step 3: Generate models**

```bash
bin/rails g model Election name:string election_date:date status:string data_mode:string
bin/rails g model Candidate election:references number:integer name:string party:string color:string photo_url:string
bin/rails g model Zone election:references code:string name:string grid_col:integer grid_row:integer
```

- [ ] **Step 4: แก้ migrations (null/default/unique index)**

แก้ migration `*_create_elections.rb`:

```ruby
class CreateElections < ActiveRecord::Migration[8.0]
  def change
    create_table :elections do |t|
      t.string :name, null: false
      t.date :election_date, null: false
      t.string :status, null: false, default: "scheduled"
      t.string :data_mode, null: false, default: "api"
      t.timestamps
    end
  end
end
```

แก้ `*_create_candidates.rb`:

```ruby
class CreateCandidates < ActiveRecord::Migration[8.0]
  def change
    create_table :candidates do |t|
      t.references :election, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :name, null: false
      t.string :party
      t.string :color, null: false, default: "#0E7A3D"
      t.string :photo_url
      t.timestamps
    end
    add_index :candidates, [:election_id, :number], unique: true
  end
end
```

แก้ `*_create_zones.rb`:

```ruby
class CreateZones < ActiveRecord::Migration[8.0]
  def change
    create_table :zones do |t|
      t.references :election, null: false, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.integer :grid_col, null: false
      t.integer :grid_row, null: false
      t.timestamps
    end
    add_index :zones, [:election_id, :code], unique: true
  end
end
```

- [ ] **Step 5: เขียน models**

`app/models/election.rb`:

```ruby
class Election < ApplicationRecord
  has_many :candidates, dependent: :destroy
  has_many :zones, dependent: :destroy

  enum :data_mode, { api: "api", manual: "manual" }, default: "api"

  validates :name, :election_date, presence: true

  def self.current = order(created_at: :desc).first
end
```

`app/models/candidate.rb`:

```ruby
class Candidate < ApplicationRecord
  belongs_to :election

  validates :number, presence: true, uniqueness: { scope: :election_id },
                     numericality: { only_integer: true, greater_than: 0 }
  validates :name, :color, presence: true
end
```

`app/models/zone.rb`:

```ruby
class Zone < ApplicationRecord
  belongs_to :election

  validates :code, presence: true, uniqueness: { scope: :election_id }
  validates :name, :grid_col, :grid_row, presence: true
end
```

- [ ] **Step 6: Migrate + รัน spec ให้ผ่าน**

```bash
bin/rails db:migrate
bundle exec rspec spec/models/core_models_spec.rb
```

Expected: PASS ทั้งหมด

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add Election, Candidate, Zone models"
```

### Task 3: Result models — VoteResult, ZoneStat, ResultRevision

**Files:**
- Test: `spec/models/result_models_spec.rb`
- Create: migrations + `app/models/vote_result.rb`, `app/models/zone_stat.rb`, `app/models/result_revision.rb`
- Modify: `app/models/candidate.rb`, `app/models/zone.rb` (เพิ่ม associations)

- [ ] **Step 1: เขียน failing spec**

Create `spec/models/result_models_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe VoteResult do
  let(:election) { build_election(zones: 1, candidates: 1) }
  let(:zone) { election.zones.first }
  let(:candidate) { election.candidates.first }

  it "rejects negative votes" do
    vr = VoteResult.new(zone:, candidate:, votes: -1, source: "api")
    expect(vr).not_to be_valid
  end

  it "enforces one row per zone+candidate" do
    VoteResult.create!(zone:, candidate:, votes: 10, source: "api")
    expect(VoteResult.new(zone:, candidate:, votes: 20, source: "api")).not_to be_valid
  end
end

RSpec.describe ZoneStat do
  it "rejects counted_percent over 100" do
    zone = build_election(zones: 1, candidates: 1).zones.first
    expect(ZoneStat.new(zone:, counted_percent: 101, source: "api")).not_to be_valid
  end
end

RSpec.describe ResultRevision do
  it "stores old and new values for a recordable" do
    election = build_election(zones: 1, candidates: 1)
    vr = VoteResult.create!(zone: election.zones.first, candidate: election.candidates.first, votes: 10, source: "api")
    rev = ResultRevision.create!(recordable: vr, old_values: { "votes" => nil },
                                 new_values: { "votes" => 10 }, source: "api")
    expect(rev.reload.new_values).to eq("votes" => 10)
    expect(rev.recordable).to eq(vr)
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/models/result_models_spec.rb
```

Expected: FAIL — `uninitialized constant VoteResult`

- [ ] **Step 3: Generate models**

```bash
bin/rails g model VoteResult zone:references candidate:references votes:integer source:string
bin/rails g model ZoneStat zone:references eligible_voters:integer turnout:integer bad_ballots:integer no_vote:integer counted_percent:decimal source:string
bin/rails g model ResultRevision recordable:references{polymorphic} old_values:jsonb new_values:jsonb source:string editor:string
```

- [ ] **Step 4: แก้ migrations**

`*_create_vote_results.rb`:

```ruby
class CreateVoteResults < ActiveRecord::Migration[8.0]
  def change
    create_table :vote_results do |t|
      t.references :zone, null: false, foreign_key: true
      t.references :candidate, null: false, foreign_key: true
      t.integer :votes, null: false, default: 0
      t.string :source, null: false, default: "api"
      t.timestamps
    end
    add_index :vote_results, [:zone_id, :candidate_id], unique: true
  end
end
```

`*_create_zone_stats.rb`:

```ruby
class CreateZoneStats < ActiveRecord::Migration[8.0]
  def change
    create_table :zone_stats do |t|
      t.references :zone, null: false, foreign_key: true, index: { unique: true }
      t.integer :eligible_voters, null: false, default: 0
      t.integer :turnout, null: false, default: 0
      t.integer :bad_ballots, null: false, default: 0
      t.integer :no_vote, null: false, default: 0
      t.decimal :counted_percent, precision: 5, scale: 2, null: false, default: 0
      t.string :source, null: false, default: "api"
      t.timestamps
    end
  end
end
```

`*_create_result_revisions.rb`:

```ruby
class CreateResultRevisions < ActiveRecord::Migration[8.0]
  def change
    create_table :result_revisions do |t|
      t.references :recordable, polymorphic: true, null: false
      t.jsonb :old_values, null: false, default: {}
      t.jsonb :new_values, null: false, default: {}
      t.string :source, null: false
      t.string :editor
      t.timestamps
    end
    add_index :result_revisions, :created_at
  end
end
```

- [ ] **Step 5: เขียน models + เพิ่ม associations**

`app/models/vote_result.rb`:

```ruby
class VoteResult < ApplicationRecord
  belongs_to :zone
  belongs_to :candidate
  has_many :result_revisions, as: :recordable, dependent: :destroy

  validates :votes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :candidate_id, uniqueness: { scope: :zone_id }
  validates :source, inclusion: { in: %w[api manual] }
end
```

`app/models/zone_stat.rb`:

```ruby
class ZoneStat < ApplicationRecord
  belongs_to :zone
  has_many :result_revisions, as: :recordable, dependent: :destroy

  validates :zone_id, uniqueness: true
  validates :eligible_voters, :turnout, :bad_ballots, :no_vote,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :counted_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :source, inclusion: { in: %w[api manual] }
end
```

`app/models/result_revision.rb`:

```ruby
class ResultRevision < ApplicationRecord
  belongs_to :recordable, polymorphic: true

  validates :source, inclusion: { in: %w[api admin] }
end
```

เพิ่มใน `app/models/candidate.rb` (ใต้ `belongs_to :election`):

```ruby
  has_many :vote_results, dependent: :destroy
```

เพิ่มใน `app/models/zone.rb` (ใต้ `belongs_to :election`):

```ruby
  has_many :vote_results, dependent: :destroy
  has_one :zone_stat, dependent: :destroy
```

- [ ] **Step 6: Migrate + รัน spec ให้ผ่าน**

```bash
bin/rails db:migrate
bundle exec rspec spec/models
```

Expected: PASS ทั้งหมด

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add VoteResult, ZoneStat, ResultRevision models"
```

---

### Task 4: Seeds — election จริง + 50 เขต + ผู้สมัครจำลอง

**Files:**
- Modify: `db/seeds.rb`

- [ ] **Step 1: เขียน seeds**

แทนที่ `db/seeds.rb` ทั้งไฟล์ (พิกัด grid_col/grid_row ยกมาจาก tile cartogram ใน mockup ที่ approve แล้ว — กริด 11 คอลัมน์ × 7 แถว):

```ruby
# 50 เขต กทม. — [ชื่อ, grid_col, grid_row] เรียงตามผัง cartogram
# code = ลำดับในผังนี้ (01-50) — adapter เป็นคนแปลงรหัสเขตของ กกต. มาเป็น code นี้
ZONES = [
  ["ดอนเมือง", 6, 1], ["สายไหม", 7, 1], ["คลองสามวา", 9, 1], ["หนองจอก", 10, 1],
  ["หลักสี่", 6, 2], ["บางเขน", 7, 2], ["ลาดพร้าว", 8, 2], ["บึงกุ่ม", 9, 2],
  ["คันนายาว", 10, 2], ["มีนบุรี", 11, 2],
  ["ทวีวัฒนา", 1, 3], ["ตลิ่งชัน", 2, 3], ["บางพลัด", 4, 3], ["บางซื่อ", 5, 3],
  ["จตุจักร", 6, 3], ["ห้วยขวาง", 7, 3], ["วังทองหลาง", 8, 3], ["บางกะปิ", 9, 3],
  ["สะพานสูง", 10, 3], ["ลาดกระบัง", 11, 3],
  ["หนองแขม", 1, 4], ["บางแค", 2, 4], ["ภาษีเจริญ", 3, 4], ["บางกอกน้อย", 4, 4],
  ["ดุสิต", 5, 4], ["พญาไท", 6, 4], ["ราชเทวี", 7, 4], ["ดินแดง", 8, 4],
  ["สวนหลวง", 9, 4], ["ประเวศ", 10, 4],
  ["บางบอน", 1, 5], ["จอมทอง", 2, 5], ["บางกอกใหญ่", 3, 5], ["ธนบุรี", 4, 5],
  ["พระนคร", 5, 5], ["ป้อมปราบฯ", 6, 5], ["ปทุมวัน", 7, 5], ["วัฒนา", 8, 5],
  ["พระโขนง", 9, 5],
  ["บางขุนเทียน", 1, 6], ["ทุ่งครุ", 2, 6], ["ราษฎร์บูรณะ", 3, 6], ["คลองสาน", 4, 6],
  ["สัมพันธวงศ์", 5, 6], ["บางรัก", 6, 6], ["สาทร", 7, 6], ["คลองเตย", 8, 6],
  ["บางนา", 9, 6],
  ["บางคอแหลม", 5, 7], ["ยานนาวา", 6, 7]
].freeze

# ข้อมูลจำลอง — แทนที่ด้วยรายชื่อจริงเมื่อ กกต. ประกาศ
CANDIDATES = [
  [1, "วรา สินธุเดช", "อิสระ", "#0E8A45"],
  [2, "เกรียงไกร บุญมาก", "ไทยนคร", "#C42B2B"],
  [3, "พิมพ์ลดา เกียรติกุล", "ก้าวกรุง", "#F47B20"],
  [4, "อรอนงค์ แสงทอง", "อิสระ", "#0FA3A3"],
  [5, "สมศักดิ์ พงศ์ธารา", "ประชารักษ์", "#1B6CC4"],
  [6, "ประพันธ์ ศรีวงศ์", "พลังเมือง", "#8B6B2E"],
  [7, "ชลธร มหานที", "อิสระ", "#7A4FBF"],
  [8, "มานพ ตั้งตรง", "อิสระ", "#5B6770"]
].freeze

election = Election.find_or_create_by!(name: "เลือกตั้งผู้ว่าราชการกรุงเทพมหานคร 2569") do |e|
  e.election_date = Date.new(2026, 6, 28)
  e.status = "scheduled"
end

ZONES.each_with_index do |(name, col, row), i|
  election.zones.find_or_create_by!(code: format("%02d", i + 1)) do |z|
    z.name = name
    z.grid_col = col
    z.grid_row = row
  end
end

CANDIDATES.each do |number, name, party, color|
  election.candidates.find_or_create_by!(number: number) do |c|
    c.name = name
    c.party = party
    c.color = color
  end
end

puts "Seeded: #{election.name} — #{election.zones.count} zones, #{election.candidates.count} candidates"
```

- [ ] **Step 2: รัน seeds + ตรวจ**

```bash
bin/rails db:seed
```

Expected: `Seeded: เลือกตั้งผู้ว่าราชการกรุงเทพมหานคร 2569 — 50 zones, 8 candidates`

```bash
bin/rails runner 'puts Zone.count'   # Expected: 50
```

- [ ] **Step 3: Commit**

```bash
git add db/seeds.rb
git commit -m "feat: seed BKK 2026 election with 50 zones and demo candidates"
```

---

### Task 5: Aggregation queries

**Files:**
- Test: `spec/models/aggregation_spec.rb`
- Modify: `app/models/election.rb`, `app/models/zone.rb`

- [ ] **Step 1: เขียน failing spec**

Create `spec/models/aggregation_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Election aggregation" do
  it "sums leaderboard votes across zones and sorts descending" do
    e = build_election(zones: 2, candidates: 2)
    z1, z2 = e.zones.order(:code).to_a
    c1, c2 = e.candidates.order(:number).to_a
    VoteResult.create!(zone: z1, candidate: c1, votes: 100, source: "api")
    VoteResult.create!(zone: z2, candidate: c1, votes: 50, source: "api")
    VoteResult.create!(zone: z1, candidate: c2, votes: 400, source: "api")

    board = e.leaderboard.to_a
    expect(board.first).to eq(c2)
    expect(board.first.total_votes).to eq(400)
    expect(board.second.total_votes).to eq(150)
    expect(e.total_votes).to eq(550)
  end

  it "averages counted_percent over all zones (zones without stats count as 0)" do
    e = build_election(zones: 2, candidates: 1)
    ZoneStat.create!(zone: e.zones.first, counted_percent: 80, source: "api")
    expect(e.counted_percent).to eq(40.0)
  end

  it "sums zone stats into a summary" do
    e = build_election(zones: 2, candidates: 1)
    z1, z2 = e.zones.to_a
    ZoneStat.create!(zone: z1, eligible_voters: 900, turnout: 500, bad_ballots: 4, no_vote: 6, counted_percent: 50, source: "api")
    ZoneStat.create!(zone: z2, eligible_voters: 800, turnout: 300, bad_ballots: 2, no_vote: 8, counted_percent: 40, source: "api")
    expect(e.stats_summary).to eq(eligible: 1700, turnout: 800, bad_ballots: 6, no_vote: 14)
  end

  it "reports the leading candidate per zone" do
    e = build_election(zones: 1, candidates: 2)
    zone = e.zones.first
    c1, c2 = e.candidates.order(:number).to_a
    VoteResult.create!(zone:, candidate: c1, votes: 10, source: "api")
    VoteResult.create!(zone:, candidate: c2, votes: 30, source: "api")
    expect(zone.leading_candidate).to eq(c2)
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/models/aggregation_spec.rb
```

Expected: FAIL — `undefined method 'leaderboard'`

- [ ] **Step 3: เพิ่ม methods**

เพิ่มใน `app/models/election.rb` (ใต้ `def self.current`):

```ruby
  # ผู้สมัครทุกคน + total_votes (SUM สดจาก 50 เขต — ไม่เก็บซ้ำ ตาม spec §6)
  def leaderboard
    candidates
      .left_joins(:vote_results)
      .select("candidates.*, COALESCE(SUM(vote_results.votes), 0) AS total_votes")
      .group("candidates.id")
      .order("total_votes DESC, candidates.number ASC")
  end

  def total_votes
    VoteResult.joins(:zone).where(zones: { election_id: id }).sum(:votes)
  end

  # เฉลี่ยทั้ง 50 เขต — เขตที่ยังไม่รายงานนับเป็น 0
  def counted_percent
    return 0.0 if zones.none?
    (ZoneStat.where(zone: zones).sum(:counted_percent) / zones.count).round(1)
  end

  def stats_summary
    stats = ZoneStat.where(zone: zones)
    {
      eligible: stats.sum(:eligible_voters),
      turnout: stats.sum(:turnout),
      bad_ballots: stats.sum(:bad_ballots),
      no_vote: stats.sum(:no_vote)
    }
  end
```

เพิ่มใน `app/models/zone.rb` (ใต้ validations):

```ruby
  def leading_candidate
    vote_results.order(votes: :desc).first&.candidate
  end
```

- [ ] **Step 4: รัน spec ให้ผ่าน**

```bash
bundle exec rspec spec/models/aggregation_spec.rb
```

Expected: PASS ทั้งหมด

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add leaderboard, counted_percent, stats aggregation"
```

## Phase 2 — Data pipeline

### Task 6: ResultWriter — จุดเดียวที่เขียนคะแนน

**Files:**
- Test: `spec/services/result_writer_spec.rb`
- Create: `app/services/result_writer.rb`

- [ ] **Step 1: เขียน failing spec**

Create `spec/services/result_writer_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ResultWriter do
  let(:election) { build_election(zones: 1, candidates: 2) }
  let(:zone) { election.zones.first }

  it "creates results and revisions on first write" do
    changed = ResultWriter.new(zone, source: "api").apply!({ 1 => 100, 2 => 80 })
    expect(changed).to be true
    expect(zone.vote_results.sum(:votes)).to eq(180)
    expect(ResultRevision.count).to eq(2)
    expect(ResultRevision.first.source).to eq("api")
  end

  it "returns false when nothing changed" do
    ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })
    expect(ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })).to be false
    expect(ResultRevision.count).to eq(1)
  end

  it "rejects decreasing votes from api (spec §7)" do
    ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })
    expect {
      ResultWriter.new(zone, source: "api").apply!({ 1 => 90 })
    }.to raise_error(ResultWriter::StaleVotesError)
    expect(zone.vote_results.first.votes).to eq(100)
  end

  it "allows decreasing votes for confirmed admin edits" do
    ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })
    ResultWriter.new(zone, source: "manual", editor: "ops@dailynews.co.th", allow_decrease: true)
      .apply!({ 1 => 90 })
    expect(zone.vote_results.first.reload.votes).to eq(90)
    rev = ResultRevision.order(:id).last
    expect(rev.source).to eq("admin")
    expect(rev.editor).to eq("ops@dailynews.co.th")
    expect(rev.old_values).to eq("votes" => 100)
  end

  it "updates zone stats with a revision" do
    ResultWriter.new(zone, source: "api")
      .apply!({}, stats: { eligible_voters: 900, turnout: 500, bad_ballots: 4, no_vote: 6, counted_percent: 55.5 })
    expect(zone.reload.zone_stat.turnout).to eq(500)
    expect(ResultRevision.last.recordable).to eq(zone.zone_stat)
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/services/result_writer_spec.rb
```

Expected: FAIL — `uninitialized constant ResultWriter`

- [ ] **Step 3: เขียน service**

Create `app/services/result_writer.rb`:

```ruby
# จุดเดียวที่แก้ VoteResult/ZoneStat ได้ — บังคับกติกา "คะแนนห้ามลด" (spec §7)
# และบันทึก ResultRevision ทุกการเปลี่ยนแปลง
class ResultWriter
  class StaleVotesError < StandardError; end

  STAT_FIELDS = %i[eligible_voters turnout bad_ballots no_vote counted_percent].freeze

  # source: "api" | "manual" (admin) — allow_decrease ใช้ได้เฉพาะ admin ที่ confirm แล้ว
  def initialize(zone, source:, editor: nil, allow_decrease: false)
    @zone = zone
    @source = source
    @editor = editor
    @allow_decrease = allow_decrease
  end

  # votes_by_number: { เบอร์ผู้สมัคร => คะแนน }, stats: hash ตาม STAT_FIELDS
  # คืน true ถ้ามีอะไรเปลี่ยนจริง (ใช้ตัดสินใจ broadcast)
  def apply!(votes_by_number, stats: nil)
    changed = false
    ActiveRecord::Base.transaction do
      votes_by_number.each do |number, votes|
        changed |= write_votes(Integer(number), Integer(votes))
      end
      changed |= write_stats(stats) if stats
    end
    changed
  end

  private

  def revision_source = @source == "api" ? "api" : "admin"

  def write_votes(number, votes)
    candidate = @zone.election.candidates.find_by!(number: number)
    result = VoteResult.find_or_initialize_by(zone: @zone, candidate: candidate)
    old = result.persisted? ? result.votes : nil
    return false if old == votes

    if old && votes < old && !@allow_decrease
      raise StaleVotesError, "zone #{@zone.code} ##{number}: #{votes} < #{old}"
    end

    result.update!(votes: votes, source: @source)
    ResultRevision.create!(recordable: result, old_values: { "votes" => old },
                           new_values: { "votes" => votes },
                           source: revision_source, editor: @editor)
    true
  end

  def write_stats(stats)
    stat = ZoneStat.find_or_initialize_by(zone: @zone)
    incoming = stats.symbolize_keys.slice(*STAT_FIELDS)
    old = incoming.keys.index_with { |f| stat.public_send(f) }
    stat.assign_attributes(incoming.merge(source: @source))
    return false unless stat.changed?

    stat.save!
    ResultRevision.create!(recordable: stat, old_values: old, new_values: incoming,
                           source: revision_source, editor: @editor)
    true
  end
end
```

- [ ] **Step 4: รัน spec ให้ผ่าน**

```bash
bundle exec rspec spec/services/result_writer_spec.rb
```

Expected: PASS ทั้งหมด

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add ResultWriter with non-decreasing guard and revisions"
```

---

### Task 7: Ingest adapter + HTTP client

**Files:**
- Test: `spec/services/ingest/ect_adapter_spec.rb`, `spec/services/ingest/client_spec.rb`
- Create: `app/services/ingest/ect_adapter.rb`, `app/services/ingest/client.rb`, `spec/fixtures/ingest/valid.json`

- [ ] **Step 1: สร้าง fixture ตาม spec API พาร์ทเนอร์**

Create `spec/fixtures/ingest/valid.json` (format นี้เป็นสมมติฐานจาก spec ที่มี — ถ้าของจริงต่าง แก้ใน adapter จุดเดียว):

```json
{
  "election": "bkk-governor-2026",
  "generated_at": "2026-06-28T20:15:00+07:00",
  "zones": [
    { "code": "01", "counted_percent": 72.5, "eligible": 91200, "turnout": 55700,
      "bad": 512, "no_vote": 701,
      "results": [ { "number": 1, "votes": 18230 }, { "number": 2, "votes": 15110 } ] },
    { "code": "02", "counted_percent": 64.0, "eligible": 80400, "turnout": 47100,
      "bad": 388, "no_vote": 540,
      "results": [ { "number": 1, "votes": 14020 }, { "number": 2, "votes": 16880 } ] }
  ]
}
```

- [ ] **Step 2: เขียน failing spec ของ adapter**

Create `spec/services/ingest/ect_adapter_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Ingest::EctAdapter do
  let(:raw) { Rails.root.join("spec/fixtures/ingest/valid.json").read }

  def parse(raw, codes: %w[01 02], numbers: [1, 2])
    described_class.parse(raw, expected_zone_codes: codes, known_numbers: numbers)
  end

  it "normalizes a valid payload" do
    r = parse(raw)
    expect(r).to be_ok
    expect(r.data["01"][:votes]).to eq(1 => 18230, 2 => 15110)
    expect(r.data["01"][:stats]).to eq(eligible_voters: 91200, turnout: 55700,
                                       bad_ballots: 512, no_vote: 701, counted_percent: 72.5)
  end

  it "rejects when zones are missing" do
    r = parse(raw, codes: %w[01 02 03])
    expect(r).not_to be_ok
    expect(r.errors.join).to include("03")
  end

  it "rejects negative votes" do
    bad = JSON.parse(raw)
    bad["zones"][0]["results"][0]["votes"] = -5
    expect(parse(bad.to_json)).not_to be_ok
  end

  it "rejects unknown candidate numbers" do
    expect(parse(raw, numbers: [1])).not_to be_ok
  end

  it "rejects invalid JSON" do
    r = parse("ไม่ใช่ json")
    expect(r).not_to be_ok
    expect(r.errors.join).to include("invalid JSON")
  end
end
```

- [ ] **Step 3: รันให้ fail**

```bash
bundle exec rspec spec/services/ingest/ect_adapter_spec.rb
```

Expected: FAIL — `uninitialized constant Ingest`

- [ ] **Step 4: เขียน adapter**

Create `app/services/ingest/ect_adapter.rb`:

```ruby
module Ingest
  # จุดเดียวที่ผูกกับ format ของ API กกต./พาร์ทเนอร์ (spec §9)
  # ถ้า spec จริงคลาดเคลื่อน แก้ mapping ที่ไฟล์นี้ไฟล์เดียว
  # นโยบาย: payload มี error ใดๆ = reject ทั้งก้อน + คืน errors ให้ caller log (spec §7)
  class EctAdapter
    Result = Struct.new(:data, :errors) do
      def ok? = errors.empty?
    end

    class << self
      def parse(raw, expected_zone_codes:, known_numbers:)
        json = JSON.parse(raw)
        zones = json["zones"]
        return Result.new({}, ["payload: zones must be an array"]) unless zones.is_a?(Array)

        errors = []
        data = {}
        missing = expected_zone_codes - zones.map { |z| z["code"].to_s }
        errors << "missing zones: #{missing.join(', ')}" if missing.any?

        zones.each do |z|
          zone_errors = validate_zone(z, known_numbers)
          if zone_errors.any?
            errors.concat(zone_errors.map { |msg| "zone #{z['code']}: #{msg}" })
          else
            data[z["code"].to_s] = normalize(z)
          end
        end
        Result.new(data, errors)
      rescue JSON::ParserError => e
        Result.new({}, ["invalid JSON: #{e.message}"])
      end

      private

      def validate_zone(z, known_numbers)
        errors = []
        results = z["results"]
        return ["results must be an array"] unless results.is_a?(Array)

        results.each do |r|
          errors << "unknown candidate ##{r['number']}" unless known_numbers.include?(r["number"])
          unless r["votes"].is_a?(Integer) && r["votes"] >= 0
            errors << "votes must be a non-negative integer (##{r['number']})"
          end
        end
        pct = z["counted_percent"]
        errors << "counted_percent out of range" unless pct.is_a?(Numeric) && pct.between?(0, 100)
        %w[eligible turnout bad no_vote].each do |field|
          errors << "#{field} must be a non-negative integer" unless z[field].is_a?(Integer) && z[field] >= 0
        end
        errors
      end

      def normalize(z)
        {
          votes: z["results"].to_h { |r| [r["number"], r["votes"]] },
          stats: {
            eligible_voters: z["eligible"], turnout: z["turnout"],
            bad_ballots: z["bad"], no_vote: z["no_vote"],
            counted_percent: z["counted_percent"]
          }
        }
      end
    end
  end
end
```

- [ ] **Step 5: รัน adapter spec ให้ผ่าน**

```bash
bundle exec rspec spec/services/ingest/ect_adapter_spec.rb
```

Expected: PASS ทั้งหมด

- [ ] **Step 6: เขียน client + spec**

Create `app/services/ingest/client.rb`:

```ruby
require "net/http"

module Ingest
  # แยก HTTP ออกมาให้ stub ง่ายใน test — retry/backoff เป็นหน้าที่ของ job
  class Client
    class FetchError < StandardError; end

    def self.fetch
      uri = URI(ENV.fetch("ECT_API_URL"))
      response = Net::HTTP.get_response(uri)
      raise FetchError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
  end
end
```

Create `spec/services/ingest/client_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Ingest::Client do
  before { ENV["ECT_API_URL"] = "https://partner.example/results" }

  it "returns the body on success" do
    allow(Net::HTTP).to receive(:get_response)
      .and_return(instance_double(Net::HTTPOK, body: "{}").tap { |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      })
    expect(described_class.fetch).to eq("{}")
  end

  it "raises FetchError on non-200" do
    allow(Net::HTTP).to receive(:get_response)
      .and_return(instance_double(Net::HTTPBadGateway, code: "502").tap { |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      })
    expect { described_class.fetch }.to raise_error(Ingest::Client::FetchError, /502/)
  end
end
```

- [ ] **Step 7: รัน spec ให้ผ่าน + commit**

```bash
bundle exec rspec spec/services/ingest
git add -A
git commit -m "feat: add ECT ingest adapter with strict validation and HTTP client"
```

---

### Task 8: ResultsSnapshot + SnapshotPublisher (results.json)

**Files:**
- Test: `spec/services/results_snapshot_spec.rb`
- Create: `app/services/results_snapshot.rb`, `app/services/snapshot_publisher.rb`
- Modify: `Gemfile` (aws-sdk-s3)

- [ ] **Step 1: เขียน failing spec**

Create `spec/services/results_snapshot_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ResultsSnapshot do
  it "builds the public payload" do
    e = build_election(zones: 2, candidates: 2)
    ResultWriter.new(e.zones.first, source: "api").apply!(
      { 1 => 100, 2 => 60 },
      stats: { eligible_voters: 500, turnout: 170, bad_ballots: 5, no_vote: 5, counted_percent: 50 }
    )

    snap = ResultsSnapshot.new(e).as_json
    expect(snap[:counted_percent]).to eq(25.0)
    expect(snap[:stats][:turnout]).to eq(170)

    top = snap[:candidates].first
    expect(top[:number]).to eq(1)
    expect(top[:votes]).to eq(100)
    expect(top[:percent]).to eq(62.5)

    z1 = snap[:zones].find { |z| z[:code] == "01" }
    expect(z1[:leader_number]).to eq(1)
    expect(z1[:top]).to eq([{ number: 1, votes: 100 }, { number: 2, votes: 60 }])
    expect(snap[:zones].size).to eq(2)
  end
end

RSpec.describe SnapshotPublisher do
  it "writes results.json to public/ outside production" do
    e = build_election(zones: 1, candidates: 1)
    path = Rails.public_path.join("results.json")
    FileUtils.rm_f(path)

    SnapshotPublisher.new(e).publish

    expect(JSON.parse(path.read)).to have_key("candidates")
  ensure
    FileUtils.rm_f(path)
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/services/results_snapshot_spec.rb
```

Expected: FAIL — `uninitialized constant ResultsSnapshot`

- [ ] **Step 3: เขียน snapshot**

Create `app/services/results_snapshot.rb`:

```ruby
# payload เดียวใช้ทั้ง polling fallback, กราฟ และ zone detail บนหน้าเว็บ
class ResultsSnapshot
  def initialize(election)
    @election = election
  end

  def as_json(*)
    total = @election.total_votes
    {
      updated_at: Time.current.iso8601,
      counted_percent: @election.counted_percent.to_f,
      stats: @election.stats_summary,
      candidates: @election.leaderboard.map do |c|
        { number: c.number, name: c.name, party: c.party, color: c.color,
          votes: c.total_votes.to_i,
          percent: total.zero? ? 0.0 : (c.total_votes * 100.0 / total).round(1) }
      end,
      zones: @election.zones.includes(:zone_stat, vote_results: :candidate).map do |z|
        top = z.vote_results.sort_by { |r| -r.votes }.first(3)
        { code: z.code, name: z.name,
          leader_number: top.first&.candidate&.number,
          counted_percent: z.zone_stat&.counted_percent.to_f,
          top: top.map { |r| { number: r.candidate.number, votes: r.votes } } }
      end
    }
  end
end
```

- [ ] **Step 4: เขียน publisher**

```bash
bundle add aws-sdk-s3 --group production --require false
```

Create `app/services/snapshot_publisher.rb`:

```ruby
# เขียน results.json ทุกครั้งที่ข้อมูลเปลี่ยน (spec §5.4)
# production → S3 (CloudFront TTL 5 วิ ชี้มาที่ key นี้) | dev/test → public/results.json
class SnapshotPublisher
  KEY = "results.json"

  def initialize(election)
    @election = election
  end

  def publish
    json = ResultsSnapshot.new(@election).as_json.to_json
    if Rails.env.production?
      require "aws-sdk-s3"
      Aws::S3::Client.new.put_object(
        bucket: ENV.fetch("SNAPSHOT_BUCKET"), key: KEY, body: json,
        content_type: "application/json", cache_control: "max-age=5"
      )
    else
      File.write(Rails.public_path.join(KEY), json)
    end
  end
end
```

- [ ] **Step 5: รัน spec ให้ผ่าน + commit**

```bash
bundle exec rspec spec/services/results_snapshot_spec.rb
git add -A
git commit -m "feat: add results.json snapshot builder and publisher"
```

---

### Task 9: IngestPollJob + ตารางรันทุก 30 วิ

**Files:**
- Test: `spec/jobs/ingest_poll_job_spec.rb`
- Create: `app/jobs/ingest_poll_job.rb`
- Modify: `config/recurring.yml`

- [ ] **Step 1: เขียน failing spec**

Create `spec/jobs/ingest_poll_job_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe IngestPollJob do
  let!(:election) { build_election(zones: 2, candidates: 2) }
  let(:raw) { Rails.root.join("spec/fixtures/ingest/valid.json").read }
  let(:publisher) { instance_double(SnapshotPublisher, publish: true) }

  before do
    allow(Ingest::Client).to receive(:fetch).and_return(raw)
    allow(SnapshotPublisher).to receive(:new).and_return(publisher)
  end

  it "writes results and stats from the API payload, then publishes snapshot" do
    described_class.perform_now
    expect(VoteResult.sum(:votes)).to eq(18230 + 15110 + 14020 + 16880)
    expect(election.zones.first.zone_stat.counted_percent).to eq(72.5)
    expect(publisher).to have_received(:publish)
  end

  it "does not publish when nothing changed" do
    described_class.perform_now
    described_class.perform_now
    expect(publisher).to have_received(:publish).once
  end

  it "skips entirely when election is in manual mode (admin override)" do
    election.update!(data_mode: "manual")
    described_class.perform_now
    expect(VoteResult.count).to eq(0)
  end

  it "rejects an invalid payload and writes nothing" do
    allow(Ingest::Client).to receive(:fetch).and_return({ zones: "เพี้ยน" }.to_json)
    allow(Rails.logger).to receive(:error)
    described_class.perform_now
    expect(VoteResult.count).to eq(0)
    expect(Rails.logger).to have_received(:error).with(/rejected/)
  end

  it "skips a zone whose votes decreased but applies the rest" do
    described_class.perform_now
    lowered = JSON.parse(raw)
    lowered["zones"][0]["results"][0]["votes"] = 1        # เขต 01 ลดลง → ข้าม
    lowered["zones"][1]["results"][0]["votes"] = 20000     # เขต 02 เพิ่ม → ใช้
    allow(Ingest::Client).to receive(:fetch).and_return(lowered.to_json)
    allow(Rails.logger).to receive(:error)
    described_class.perform_now
    z1, z2 = election.zones.order(:code).to_a
    expect(z1.vote_results.joins(:candidate).find_by(candidates: { number: 1 }).votes).to eq(18230)
    expect(z2.vote_results.joins(:candidate).find_by(candidates: { number: 1 }).votes).to eq(20000)
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/jobs/ingest_poll_job_spec.rb
```

Expected: FAIL — `uninitialized constant IngestPollJob`

- [ ] **Step 3: เขียน job**

Create `app/jobs/ingest_poll_job.rb`:

```ruby
class IngestPollJob < ApplicationJob
  queue_as :default

  # API ล่ม/timeout → exponential backoff (spec §7) — รอบถัดไปของ recurring จะมาใน 30 วิอยู่แล้ว
  retry_on Ingest::Client::FetchError, wait: :polynomially_longer, attempts: 5

  def perform
    election = Election.current
    return if election.nil? || election.manual?

    parsed = Ingest::EctAdapter.parse(
      Ingest::Client.fetch,
      expected_zone_codes: election.zones.pluck(:code),
      known_numbers: election.candidates.pluck(:number)
    )
    unless parsed.ok?
      Rails.logger.error("[ingest] rejected payload: #{parsed.errors.join('; ')}")
      return
    end

    changed = false
    election.zones.find_each do |zone|
      payload = parsed.data[zone.code] or next
      begin
        changed |= ResultWriter.new(zone, source: "api").apply!(payload[:votes], stats: payload[:stats])
      rescue ResultWriter::StaleVotesError => e
        Rails.logger.error("[ingest] #{e.message} — zone skipped")
      end
    end

    SnapshotPublisher.new(election).publish if changed
  end
end
```

(การ broadcast Turbo Streams จะถูกเพิ่มเข้า job นี้ใน Task 11 — ตอนนี้ยังไม่มี ResultsBroadcaster)

- [ ] **Step 4: รัน spec ให้ผ่าน**

```bash
bundle exec rspec spec/jobs/ingest_poll_job_spec.rb
```

Expected: PASS ทั้งหมด

- [ ] **Step 5: ตั้ง recurring schedule**

แทนที่ `config/recurring.yml`:

```yaml
production:
  ingest_poll:
    class: IngestPollJob
    queue: default
    schedule: every 30 seconds

development:
  ingest_poll:
    class: IngestPollJob
    queue: default
    schedule: every 30 seconds
```

(dev จะ error ถ้าไม่ตั้ง `ECT_API_URL` — job จะ retry แล้วหยุดเอง ไม่กระทบหน้าเว็บ
ทดสอบ pipeline จริงใน dev: ตั้ง `ECT_API_URL` ชี้ mock server หรือใช้ admin panel)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add IngestPollJob polling partner API every 30s"
```

## Phase 3 — Public site

### Task 10: Dashboard page (static render ตาม mockup v1)

**Files:**
- Test: `spec/requests/dashboard_spec.rb`
- Create: `app/controllers/dashboard_controller.rb`, `app/views/dashboard/show.html.erb` + partials `_site_header`, `_header_status`, `_hero`, `_leaderboard`, `_map`, `_stats`, `_news`
- Modify: `config/routes.rb`, `app/views/layouts/application.html.erb`, `app/assets/stylesheets/application.css`

- [ ] **Step 1: เขียน failing request spec**

Create `spec/requests/dashboard_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  include ElectionSetup

  it "renders leaderboard and one tile per zone" do
    build_election(zones: 3, candidates: 2)
    get "/"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ผู้สมัคร 1")
    expect(response.body.scan('class="tile"').size).to eq(3)
  end

  it "renders an empty state when no election exists" do
    get "/"
    expect(response.body).to include("ยังไม่เปิดรายงานผล")
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/requests/dashboard_spec.rb
```

Expected: FAIL — routing error (no route matches `/`)

- [ ] **Step 3: Route + controller**

ใน `config/routes.rb` เพิ่มในบล็อก `Rails.application.routes.draw`:

```ruby
  root "dashboard#show"
```

Create `app/controllers/dashboard_controller.rb`:

```ruby
class DashboardController < ApplicationController
  def show
    @election = Election.current
  end
end
```

- [ ] **Step 4: Layout + CSS จาก mockup**

แก้ `app/views/layouts/application.html.erb` — เปลี่ยน `<html>` เป็น `<html lang="th">` และเพิ่มใน `<head>` ก่อน `stylesheet_link_tag`:

```erb
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Prompt:wght@400;500;600;700;800&family=Anuphan:wght@400;500;600&display=swap" rel="stylesheet">
```

CSS: เปิด `docs/mockups/election-ui-mockup.html` คัดลอกเนื้อหาในแท็ก `<style>` **ทั้งบล็อก** (เริ่มบรรทัด `/* ============ Design tokens — Dailynews CI ============ */` จบที่ block `@media (prefers-reduced-motion:reduce){...}`) ไปต่อท้าย `app/assets/stylesheets/application.css` แล้ว**ลบ 5 selector ของ demo chrome ออก**: `.demo-pill`, `.view-toggle`, `.phone-overlay` (รวม `.show`), `.phone-frame` (รวม `::after`, `iframe`), `.phone-close` — ที่เหลือใช้ class ชื่อเดิมทั้งหมด

- [ ] **Step 5: View หลัก**

Create `app/views/dashboard/show.html.erb`:

```erb
<% if @election.nil? %>
  <main class="wrap"><p>ยังไม่เปิดรายงานผล</p></main>
<% else %>
  <%= render "site_header", election: @election %>
  <%= render "hero", election: @election %>
  <main class="wrap" data-controller="live-flash fallback">
    <%= render "leaderboard", election: @election %>
    <%= render "map", election: @election %>
    <%= render "stats", election: @election %>
    <%= render "news" %>
  </main>
  <footer>ผลคะแนนอย่างไม่เป็นทางการ — รวบรวมโดยทีมข่าวเดลินิวส์</footer>
<% end %>
```

(`data-controller="live-flash fallback"` จะเริ่มทำงานเมื่อสร้าง controllers ใน Task 11/13 — ระหว่างนี้ Stimulus เฉยๆ ไม่ error)

- [ ] **Step 6: Partials**

หมายเหตุทุก partial: ไอคอน `<svg>` ประกอบหัว card ให้คัดลอกจาก section เดียวกันใน
`docs/mockups/election-ui-mockup.html` (มาร์กอัป `.card-head svg` ตรงกันทุกตัว) — โค้ดข้างล่างละไว้เพื่อความกระชับ

Create `app/views/dashboard/_site_header.html.erb`:

```erb
<header class="site-head">
  <div class="inner">
    <div class="brand">
      <div class="logo">DAILY<span>NEWS</span></div>
      <div class="event">เลือกตั้งผู้ว่าฯ กทม. 2569</div>
    </div>
    <%= render "header_status", election: election %>
  </div>
</header>
```

Create `app/views/dashboard/_header_status.html.erb` (root element ต้องมี `id="header-status"` — เป็น broadcast target):

```erb
<div class="head-status" id="header-status">
  <div class="counted">
    <div class="label">
      <span>นับคะแนนแล้ว</span>
      <b class="num" data-live="counted-pct"><%= election.counted_percent %>%</b>
    </div>
    <div class="bar"><i style="width: <%= election.counted_percent %>%"></i></div>
  </div>
  <span style="font-size: 12px; color: var(--muted)">อัปเดต
    <b class="num" data-live="updated-at"><%= Time.current.strftime("%H:%M:%S") %> น.</b>
  </span>
  <div class="live"><span class="dot"></span>LIVE</div>
</div>
```

(เวลานี้ render ใหม่ทุกครั้งที่ broadcast — spec §7: หน้าเว็บแสดงข้อมูลล่าสุด + เวลาอัปเดตเสมอ)

Create `app/views/dashboard/_hero.html.erb`:

```erb
<section class="hero">
  <div class="kicker">เกาะติดสถานการณ์เลือกตั้ง</div>
  <h1>ผลเลือกตั้งผู้ว่าราชการกรุงเทพมหานคร 2569</h1>
  <div class="meta">
    <span>ผลอย่างไม่เป็นทางการ • อัปเดตอัตโนมัติ</span>
  </div>
</section>
```

Create `app/views/dashboard/_leaderboard.html.erb` (root `id="leaderboard"`):

```erb
<% board = election.leaderboard.to_a %>
<% total = board.sum { |c| c.total_votes.to_i } %>
<% top_votes = board.first ? board.first.total_votes.to_i : 0 %>
<section class="card sec-lead" id="leaderboard">
  <div class="card-head">
    <h2>อันดับคะแนน (ไม่เป็นทางการ)</h2>
    <span class="hint">เรียงตามคะแนนรวม 50 เขต</span>
  </div>
  <div class="podium">
    <% board.first(3).each_with_index do |c, i| %>
      <article class="cand <%= "first" if i.zero? %>" style="--c: <%= c.color %>">
        <div class="avatar-wrap">
          <div class="avatar"><%= c.name.first %></div>
          <div class="cand-no num"><%= c.number %></div>
        </div>
        <div class="cand-info">
          <span class="rank-chip">อันดับ <%= i + 1 %></span>
          <div class="name"><%= c.name %></div>
          <div class="party">เบอร์ <%= c.number %> • <%= c.party %></div>
        </div>
        <div class="cand-score">
          <div class="votes num" data-live="votes-<%= c.number %>"><%= number_with_delimiter(c.total_votes) %></div>
          <div class="pct num" data-live="pct-<%= c.number %>"><%= total.zero? ? 0.0 : (c.total_votes * 100.0 / total).round(1) %>%</div>
        </div>
        <div class="cand-bar"><i style="width: <%= top_votes.zero? ? 0 : (c.total_votes * 100.0 / top_votes).round(1) %>%; background: <%= c.color %>"></i></div>
      </article>
    <% end %>
  </div>
  <div class="minor">
    <table aria-label="ผู้สมัครอันดับ 4 ขึ้นไป">
      <thead><tr><th>ผู้สมัคร</th><th>สังกัด</th><th>คะแนน</th></tr></thead>
      <tbody>
        <% board.drop(3).each_with_index do |c, i| %>
          <tr>
            <td><span class="mini-no num" style="background: <%= c.color %>"><%= c.number %></span><%= i + 4 %>. <%= c.name %></td>
            <td style="color: var(--muted)"><%= c.party %></td>
            <td><span class="v num" data-live="votes-<%= c.number %>"><%= number_with_delimiter(c.total_votes) %></span></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </div>
</section>
```

Create `app/views/dashboard/_map.html.erb` (root `id="zone-map"`):

```erb
<% zones = election.zones.includes(:zone_stat, vote_results: :candidate).sort_by(&:code) %>
<section class="card sec-map" id="zone-map" data-controller="zone-detail">
  <div class="card-head">
    <h2>ผลนำรายเขต — 50 เขต</h2>
    <span class="hint">แตะเขตเพื่อดูคะแนน</span>
  </div>
  <div class="map-body">
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
    <div class="zone-detail" data-zone-detail-target="panel">
      <div class="zd-head">
        <h3 data-zone-detail-target="name"></h3>
        <span class="zd-counted num" data-zone-detail-target="counted"></span>
        <button type="button" class="zd-close" data-action="zone-detail#hide" aria-label="ปิดรายละเอียดเขต">✕</button>
      </div>
      <div data-zone-detail-target="rows"></div>
    </div>
  </div>
</section>
```

Create `app/views/dashboard/_stats.html.erb` (root `id="overview-stats"`):

```erb
<% summary = election.stats_summary %>
<% ballots = summary[:turnout] %>
<section class="card sec-chart" id="overview-stats">
  <div class="card-head"><h2>สถิติภาพรวม</h2></div>
  <div class="grid">
    <div class="stat t">
      <div class="s-label">ผู้มาใช้สิทธิ (จากหน่วยที่นับแล้ว)</div>
      <div class="s-value num" data-live="turnout-pct"><%= summary[:eligible].zero? ? "–" : "#{(ballots * 100.0 / summary[:eligible]).round(1)}%" %></div>
      <div class="s-sub num"><%= number_with_delimiter(ballots) %> คน</div>
    </div>
    <div class="stat">
      <div class="s-label">บัตรเสีย</div>
      <div class="s-value num"><%= ballots.zero? ? "–" : "#{(summary[:bad_ballots] * 100.0 / ballots).round(1)}%" %></div>
      <div class="s-sub">ของบัตรทั้งหมดที่นับแล้ว</div>
    </div>
    <div class="stat">
      <div class="s-label">ไม่ประสงค์ลงคะแนน</div>
      <div class="s-value num"><%= ballots.zero? ? "–" : "#{(summary[:no_vote] * 100.0 / ballots).round(1)}%" %></div>
      <div class="s-sub">ของบัตรทั้งหมดที่นับแล้ว</div>
    </div>
  </div>
  <div class="chart-box">
    <div class="c-title">คะแนนสะสม 3 อันดับแรก</div>
    <svg class="chart-svg" data-controller="trend-chart" viewBox="0 0 600 200" preserveAspectRatio="none"
         role="img" aria-label="กราฟคะแนนสะสมของผู้สมัคร 3 อันดับแรก"></svg>
    <div class="chart-legend" id="chart-legend"></div>
  </div>
</section>
```

Create `app/views/dashboard/_news.html.erb` (เวอร์ชัน placeholder — Task 14 เติมข่าวจริง):

```erb
<section class="card sec-news" id="news">
  <div class="card-head"><h2>เกาะติดจาก Dailynews</h2></div>
  <div class="news-list">
    <p style="padding: 14px 16px; color: var(--muted)">กำลังรวบรวมข่าวล่าสุด...</p>
  </div>
</section>
```

- [ ] **Step 7: รัน spec + ดูของจริง**

```bash
bundle exec rspec spec/requests/dashboard_spec.rb   # Expected: PASS
bin/dev
```

เปิด `http://localhost:3000` — ต้องเห็น layout ตาม mockup: header + hero เขียว + leaderboard
(คะแนน 0 ทุกคน) + แผนที่ 50 เขตสีเทา (ยังไม่มีผล) + สถิติ "–"
เทียบกับ `docs/mockups/election-ui-mockup.html` ว่าหน้าตาตรงกัน

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: public dashboard page per approved v1 mockup"
```

---

### Task 11: Realtime — ResultsBroadcaster + Turbo Streams + flash

**Files:**
- Test: `spec/services/results_broadcaster_spec.rb`
- Create: `app/services/results_broadcaster.rb`, `app/javascript/controllers/live_flash_controller.js`
- Modify: `app/views/dashboard/show.html.erb`, `app/jobs/ingest_poll_job.rb`, `spec/jobs/ingest_poll_job_spec.rb`

- [ ] **Step 1: เขียน failing spec**

Create `spec/services/results_broadcaster_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ResultsBroadcaster, type: :channel do
  include ElectionSetup

  it "broadcasts replacements for all 4 live regions" do
    e = build_election(zones: 1, candidates: 1)
    expect {
      ResultsBroadcaster.new(e).broadcast_all
    }.to have_broadcasted_to("results").exactly(4).times
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/services/results_broadcaster_spec.rb
```

Expected: FAIL — `uninitialized constant ResultsBroadcaster`

- [ ] **Step 3: เขียน broadcaster**

Create `app/services/results_broadcaster.rb`:

```ruby
# push อัปเดตทุก region ของหน้า dashboard ผ่าน stream "results"
# target id ต้องตรงกับ root element ของแต่ละ partial (Task 10)
class ResultsBroadcaster
  REGIONS = [
    ["header-status",  "dashboard/header_status"],
    ["leaderboard",    "dashboard/leaderboard"],
    ["zone-map",       "dashboard/map"],
    ["overview-stats", "dashboard/stats"]
  ].freeze

  def initialize(election)
    @election = election
  end

  def broadcast_all
    REGIONS.each do |target, partial|
      Turbo::StreamsChannel.broadcast_replace_to(
        "results", target: target, partial: partial, locals: { election: @election }
      )
    end
  end
end
```

- [ ] **Step 4: รัน spec ให้ผ่าน**

```bash
bundle exec rspec spec/services/results_broadcaster_spec.rb
```

Expected: PASS

- [ ] **Step 5: ต่อเข้าหน้าเว็บ + job**

ใน `app/views/dashboard/show.html.erb` เพิ่มบรรทัดแรกใน branch `else` (ก่อน render site_header):

```erb
  <%= turbo_stream_from "results" %>
```

ใน `app/jobs/ingest_poll_job.rb` แก้บรรทัดสุดท้ายของ `perform` เป็น:

```ruby
    if changed
      ResultsBroadcaster.new(election).broadcast_all
      SnapshotPublisher.new(election).publish
    end
```

ใน `spec/jobs/ingest_poll_job_spec.rb` เพิ่ม stub ใน `before` block:

```ruby
    allow(ResultsBroadcaster).to receive(:new)
      .and_return(instance_double(ResultsBroadcaster, broadcast_all: true))
```

- [ ] **Step 6: Stimulus flash controller (visual feedback ตาม spec §4)**

Create `app/javascript/controllers/live_flash_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// เมื่อ Turbo Stream สลับ DOM ใหม่ ให้ตัวเลข [data-live] ที่ค่าเปลี่ยนวูบสีเหลือง (.flash)
export default class extends Controller {
  connect() {
    this.snapshot()
    this.observer = new MutationObserver(() => this.flashChanged())
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  snapshot() {
    this.values = {}
    this.element.querySelectorAll("[data-live]").forEach(el => {
      this.values[el.dataset.live] = el.textContent
    })
  }

  flashChanged() {
    this.element.querySelectorAll("[data-live]").forEach(el => {
      const key = el.dataset.live
      if (this.values[key] !== undefined && this.values[key] !== el.textContent) {
        el.classList.remove("flash")
        void el.offsetWidth
        el.classList.add("flash")
      }
    })
    this.snapshot()
  }
}
```

(class `.flash` มีอยู่แล้วใน CSS ที่คัดลอกจาก mockup — สังเกตว่า observer ดูแค่ childList
จึงไม่วนลูปกับการเพิ่ม class ของตัวเอง)

- [ ] **Step 7: ทดสอบทั้งระบบด้วยมือ**

```bash
bundle exec rspec          # ทุก spec ต้องผ่าน
bin/dev
```

เปิด browser 2 แท็บที่ `http://localhost:3000` แล้วใน terminal ใหม่:

```bash
bin/rails runner '
  e = Election.current
  ResultWriter.new(e.zones.first, source: "manual", editor: "test").apply!({ 1 => 12345 }, stats: { eligible_voters: 90000, turnout: 50000, bad_ballots: 100, no_vote: 200, counted_percent: 55 })
  ResultsBroadcaster.new(e).broadcast_all
  SnapshotPublisher.new(e).publish
'
```

Expected: ทั้ง 2 แท็บอัปเดตภายใน ~1 วิโดยไม่ refresh — คะแนนเบอร์ 1 เป็น 12,345
พร้อม flash สีเหลือง, แถบนับคะแนนขยับ, เขต 01 บนแผนที่เปลี่ยนเป็นสีเขียว

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: realtime Turbo Streams broadcast with flash feedback"
```

### Task 12: กราฟแนวโน้ม + zone detail (client JS จาก results.json)

**Files:**
- Create: `app/javascript/controllers/trend_chart_controller.js`, `app/javascript/controllers/zone_detail_controller.js`

- [ ] **Step 1: trend chart controller**

Create `app/javascript/controllers/trend_chart_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// กราฟคะแนนสะสม 3 อันดับแรก — ดึงจุดใหม่จาก results.json ทุก 30 วิ (เท่าจังหวะ ingest)
export default class extends Controller {
  connect() {
    this.history = new Map() // number -> [votes...]
    this.poll()
    this.timer = setInterval(() => this.poll(), 30000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    try {
      const res = await fetch("/results.json", { cache: "no-store" })
      if (!res.ok) return
      const data = await res.json()
      const top3 = data.candidates.slice(0, 3)
      top3.forEach(c => {
        const pts = this.history.get(c.number) || []
        if (pts[pts.length - 1] !== c.votes) pts.push(c.votes)
        if (pts.length > 12) pts.shift()
        this.history.set(c.number, pts)
      })
      this.draw(top3)
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  draw(top3) {
    const W = 600, H = 200, P = 8
    const max = Math.max(1, ...top3.flatMap(c => this.history.get(c.number) || [])) * 1.08
    const line = pts => pts.map((v, i) =>
      `${i === 0 ? "M" : "L"}${(P + i * (W - 2 * P) / Math.max(1, pts.length - 1)).toFixed(1)},` +
      `${(H - P - (v / max) * (H - 2 * P)).toFixed(1)}`).join(" ")

    this.element.innerHTML =
      [40, 80, 120, 160].map(y =>
        `<line x1="0" y1="${y}" x2="${W}" y2="${y}" stroke="#EEE8EF" stroke-width="1"/>`).join("") +
      top3.map(c => {
        const pts = this.history.get(c.number) || []
        if (pts.length === 0) return ""
        const x = P + (pts.length - 1) * (W - 2 * P) / Math.max(1, pts.length - 1)
        const y = H - P - (pts[pts.length - 1] / max) * (H - 2 * P)
        return `<path d="${line(pts)} L${x.toFixed(1)},${H - P} L${P},${H - P} Z" fill="${c.color}" opacity="0.07"/>` +
               `<path d="${line(pts)}" fill="none" stroke="${c.color}" stroke-width="2.5" stroke-linejoin="round"/>` +
               `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="4" fill="${c.color}"/>`
      }).join("")

    const legend = document.getElementById("chart-legend")
    if (legend) legend.innerHTML = top3.map(c =>
      `<span><i style="background:${c.color}"></i>${c.name}</span>`).join("")
  }
}
```

- [ ] **Step 2: zone detail controller**

Create `app/javascript/controllers/zone_detail_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// คลิกเขตบนแผนที่ → ดึง top 3 ของเขตจาก results.json มาแสดงใน panel
export default class extends Controller {
  static targets = ["panel", "name", "counted", "rows"]

  async show(event) {
    const code = event.currentTarget.dataset.zoneCode
    this.element.querySelectorAll(".tile.sel").forEach(t => t.classList.remove("sel"))
    event.currentTarget.classList.add("sel")
    try {
      const res = await fetch("/results.json", { cache: "no-store" })
      if (!res.ok) return
      const data = await res.json()
      const zone = data.zones.find(z => z.code === code)
      if (!zone) return
      const byNumber = new Map(data.candidates.map(c => [c.number, c]))
      const sum = zone.top.reduce((s, t) => s + t.votes, 0)
      this.nameTarget.textContent = `เขต${zone.name}`
      this.countedTarget.textContent = `นับแล้ว ${zone.counted_percent}%`
      this.rowsTarget.innerHTML = zone.top.map(t => {
        const c = byNumber.get(t.number)
        const pct = sum === 0 ? 0 : (t.votes * 100 / sum).toFixed(1)
        return `<div class="zd-row">
          <i style="background:${c.color}"></i>
          <span class="zd-name">เบอร์ ${c.number} ${c.name}</span>
          <span class="zd-v num">${t.votes.toLocaleString("th-TH")} (${pct}%)</span>
        </div>`
      }).join("")
      this.panelTarget.classList.add("show")
    } catch { /* เงียบไว้ */ }
  }

  hide() {
    this.panelTarget.classList.remove("show")
    this.element.querySelectorAll(".tile.sel").forEach(t => t.classList.remove("sel"))
  }
}
```

- [ ] **Step 3: ทดสอบด้วยมือ**

```bash
bin/dev
```

รัน runner snippet จาก Task 11 Step 7 อีกครั้งเพื่อให้มี `public/results.json` แล้วเปิดหน้าเว็บ:
- กราฟแสดงเส้น 3 สี (จุดเดียวตอนแรก เพิ่มจุดเมื่อข้อมูลเปลี่ยน)
- คลิกเขต 01 → panel แสดง "เขต…" + คะแนน top 3 + ปุ่มปิดทำงาน

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: trend chart and zone detail from results.json"
```

---

### Task 13: Polling fallback เมื่อ WebSocket หลุด

**Files:**
- Create: `app/javascript/controllers/fallback_controller.js`
- Modify: `app/views/dashboard/show.html.erb` (มี data-controller="fallback" แล้วจาก Task 10 — ไม่ต้องแก้)

- [ ] **Step 1: เขียน fallback controller**

Create `app/javascript/controllers/fallback_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// ตาข่ายนิรภัย (spec §7): ถ้าไม่มี Turbo Stream เข้ามาเกิน staleAfter
// ให้ poll results.json (ผ่าน CDN ใน production) ทุก interval มาอัปเดตตัวเลขแทน
// — Turbo ต่อ WebSocket ใหม่เองเบื้องหลัง เมื่อ stream กลับมา fallback จะหยุดเอง
// หมายเหตุ: ช่วงคะแนนนิ่ง (ไม่มี broadcast จริงๆ) จะ poll ฟรี — ตั้งใจ เพราะถูกผ่าน CDN
// และทำให้ recover อัตโนมัติโดยไม่ต้องเช็คสถานะ socket ตรงๆ
export default class extends Controller {
  static values = {
    url: { type: String, default: "/results.json" },
    interval: { type: Number, default: 10000 },
    staleAfter: { type: Number, default: 15000 }
  }

  connect() {
    this.lastStream = Date.now()
    this.onStream = () => { this.lastStream = Date.now() }
    document.addEventListener("turbo:before-stream-render", this.onStream)
    this.timer = setInterval(() => this.maybePoll(), this.intervalValue)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.onStream)
    clearInterval(this.timer)
  }

  async maybePoll() {
    if (Date.now() - this.lastStream < this.staleAfterValue) return
    try {
      const res = await fetch(this.urlValue, { cache: "no-store" })
      if (!res.ok) return
      this.patch(await res.json())
    } catch { /* เครือข่ายล้ม — รอบหน้าลองใหม่ */ }
  }

  patch(data) {
    const set = (key, text) => document.querySelectorAll(`[data-live="${key}"]`).forEach(el => {
      if (el.textContent !== text) el.textContent = text
    })
    data.candidates.forEach(c => {
      set(`votes-${c.number}`, c.votes.toLocaleString("th-TH"))
      set(`pct-${c.number}`, `${c.percent}%`)
    })
    set("counted-pct", `${data.counted_percent}%`)
    set("updated-at", `${new Date(data.updated_at).toLocaleTimeString("th-TH")} น.`)
    data.zones.forEach(z => {
      const tile = document.querySelector(`[data-zone-code="${z.code}"]`)
      const cand = data.candidates.find(c => c.number === z.leader_number)
      if (tile && cand) tile.style.setProperty("--c", cand.color)
    })
  }
}
```

(การแก้ textContent เป็น childList mutation → live-flash controller จาก Task 11
จะ flash ตัวเลขให้เหมือนตอนรับผ่าน WS)

- [ ] **Step 2: ทดสอบด้วยมือ**

1. `bin/dev` เปิดหน้าเว็บ
2. ใน DevTools → Network → ปิด WS: filter `cable` แล้ว block request URL (หรือหยุด
   process `bin/dev` แล้วเสิร์ฟ static ด้วย `python3 -m http.server` ไม่ได้ — ใช้วิธี block ใน DevTools)
3. รัน runner snippet (Task 11 Step 7) เพื่อเปลี่ยนคะแนน + เขียน results.json ใหม่
4. Expected: ภายใน ~10-25 วิ ตัวเลขบนหน้าอัปเดตจากการ poll (ดู Network เห็น request
   `results.json` ทุก 10 วิ) พร้อม flash

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: client polling fallback when WebSocket is silent"
```

---

### Task 14: ข่าวจาก Dailynews (RSS + cache)

**Files:**
- Test: `spec/services/news/fetcher_spec.rb`
- Create: `app/services/news/fetcher.rb`, `spec/fixtures/news/feed.xml`
- Modify: `app/views/dashboard/_news.html.erb`

- [ ] **Step 1: สร้าง fixture**

Create `spec/fixtures/news/feed.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Dailynews</title>
    <item>
      <title>ข่าวเลือกตั้ง 1</title>
      <link>https://www.dailynews.co.th/news/1/</link>
      <pubDate>Sun, 28 Jun 2026 18:45:00 +0700</pubDate>
    </item>
    <item>
      <title>ข่าวเลือกตั้ง 2</title>
      <link>https://www.dailynews.co.th/news/2/</link>
      <pubDate>Sun, 28 Jun 2026 19:20:00 +0700</pubDate>
    </item>
  </channel>
</rss>
```

- [ ] **Step 2: เขียน failing spec**

Create `spec/services/news/fetcher_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe News::Fetcher do
  before { Rails.cache.clear }

  it "parses feed items" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    items = described_class.latest(limit: 2)
    expect(items.size).to eq(2)
    expect(items.first.title).to eq("ข่าวเลือกตั้ง 1")
    expect(items.first.url).to eq("https://www.dailynews.co.th/news/1/")
    expect(items.first.published_at).to be_a(Time)
  end

  it "returns [] when the feed is unreachable" do
    allow(described_class).to receive(:fetch_xml).and_raise(SocketError)
    expect(described_class.latest).to eq([])
  end
end
```

- [ ] **Step 3: รันให้ fail**

```bash
bundle exec rspec spec/services/news/fetcher_spec.rb
```

Expected: FAIL — `uninitialized constant News`

- [ ] **Step 4: เขียน fetcher**

Create `app/services/news/fetcher.rb`:

```ruby
require "rss"
require "open-uri"

module News
  # ดึงข่าวจากเว็บหลัก dailynews.co.th — ไม่เก็บในระบบนี้ (spec §6)
  # พังเมื่อไหร่คืน [] — หน้าเว็บผลคะแนนห้ามล่มเพราะข่าว
  class Fetcher
    FEED_URL = ENV.fetch("NEWS_FEED_URL", "https://www.dailynews.co.th/feed/")
    Item = Struct.new(:title, :url, :published_at)

    def self.latest(limit: 3)
      Rails.cache.fetch("news/latest/#{limit}", expires_in: 5.minutes) do
        feed = RSS::Parser.parse(fetch_xml, false)
        feed.items.first(limit).map { |i| Item.new(i.title, i.link, i.pubDate) }
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

- [ ] **Step 5: รัน spec ให้ผ่าน**

```bash
bundle exec rspec spec/services/news/fetcher_spec.rb
```

Expected: PASS

- [ ] **Step 6: เติม partial ข่าว**

แทนที่ `app/views/dashboard/_news.html.erb` ทั้งไฟล์:

```erb
<% items = News::Fetcher.latest(limit: 3) %>
<section class="card sec-news" id="news">
  <div class="card-head"><h2>เกาะติดจาก Dailynews</h2></div>
  <div class="news-list">
    <% if items.empty? %>
      <p style="padding: 14px 16px; color: var(--muted)">ติดตามข่าวเลือกตั้งทั้งหมดได้ที่ dailynews.co.th</p>
    <% else %>
      <% items.each do |item| %>
        <a class="news-item" href="<%= item.url %>" target="_blank" rel="noopener">
          <div class="news-thumb"></div>
          <div>
            <h3><%= item.title %></h3>
            <time><%= item.published_at&.strftime("%d/%m/%Y • %H:%M น.") %></time>
          </div>
        </a>
      <% end %>
    <% end %>
  </div>
  <a class="news-more" href="https://www.dailynews.co.th" target="_blank" rel="noopener">อ่านข่าวเลือกตั้งทั้งหมด →</a>
</section>
```

- [ ] **Step 7: รันทุก spec + commit**

```bash
bundle exec rspec
git add -A
git commit -m "feat: pull latest Dailynews headlines via RSS with cache"
```

## Phase 4 — Admin & Ops

### Task 15: Admin authentication (Rails 8 generator)

**Files:**
- Create: ผ่าน generator — `app/models/user.rb`, `app/models/session.rb`, `app/controllers/sessions_controller.rb`, `app/controllers/concerns/authentication.rb`, migrations, views
- Modify: `app/controllers/dashboard_controller.rb`, `db/seeds.rb`, `spec/requests/dashboard_spec.rb`
- Create: `spec/support/sign_in_helper.rb`

- [ ] **Step 1: รัน generator + migrate**

```bash
bin/rails generate authentication
bin/rails db:migrate
```

Expected: สร้าง User/Session models + `Authentication` concern ที่บังคับ login ทุก controller

- [ ] **Step 2: เปิด public access ให้ dashboard**

generator ทำให้ทุก controller ต้อง login — หน้า public ต้องยกเว้น
แก้ `app/controllers/dashboard_controller.rb` เพิ่มบรรทัดแรกในคลาส:

```ruby
  allow_unauthenticated_access
```

- [ ] **Step 3: seed admin user**

ต่อท้าย `db/seeds.rb`:

```ruby
if Rails.env.development?
  User.find_or_create_by!(email_address: ENV.fetch("ADMIN_EMAIL", "admin@dailynews.local")) do |u|
    u.password = ENV.fetch("ADMIN_PASSWORD", "election2026")
  end
  puts "Admin user: #{ENV.fetch('ADMIN_EMAIL', 'admin@dailynews.local')}"
end
# production: สร้าง admin ด้วย ADMIN_EMAIL/ADMIN_PASSWORD ผ่าน
#   bin/rails runner 'User.create!(email_address: ENV.fetch("ADMIN_EMAIL"), password: ENV.fetch("ADMIN_PASSWORD"))'
```

```bash
bin/rails db:seed
```

- [ ] **Step 4: sign-in helper สำหรับ request specs**

Create `spec/support/sign_in_helper.rb`:

```ruby
module SignInHelper
  def sign_in_as(user, password: "election2026")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  def create_admin
    User.create!(email_address: "ops@dailynews.local", password: "election2026")
  end
end

RSpec.configure { |config| config.include SignInHelper, type: :request }
```

- [ ] **Step 5: กัน regression — dashboard ต้องเข้าได้โดยไม่ login**

รัน spec เดิมทั้งหมด:

```bash
bundle exec rspec
```

Expected: PASS ทั้งหมด (ถ้า dashboard spec fail แปลว่า allow_unauthenticated_access ไม่ทำงาน)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: admin authentication via Rails 8 generator"
```

---

### Task 16: Admin panel — กรอกคะแนน + สลับโหมด api⇄manual

**Files:**
- Test: `spec/requests/admin_spec.rb`
- Create: `app/controllers/admin/dashboard_controller.rb`, `app/controllers/admin/zone_results_controller.rb`, `app/controllers/admin/elections_controller.rb`, views `app/views/admin/dashboard/index.html.erb`, `app/views/admin/zone_results/edit.html.erb`
- Modify: `config/routes.rb`

- [ ] **Step 1: เขียน failing spec**

Create `spec/requests/admin_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin panel", type: :request do
  include ElectionSetup

  let!(:election) { build_election(zones: 1, candidates: 2) }
  let(:zone) { election.zones.first }
  let(:admin) { create_admin }

  it "redirects unauthenticated users to login" do
    get admin_root_path
    expect(response).to redirect_to(new_session_path)
  end

  describe "เมื่อ login แล้ว" do
    before { sign_in_as(admin) }

    it "shows the zone list" do
      get admin_root_path
      expect(response.body).to include("เขต 1")
    end

    it "requires the confirm checkbox before saving" do
      patch admin_zone_result_path(zone), params: { votes: { "1" => "999" } }
      expect(zone.vote_results.count).to eq(0)
      expect(flash[:alert]).to include("ยืนยัน")
    end

    it "saves manual results with revision attributed to the editor" do
      patch admin_zone_result_path(zone), params: {
        confirm: "1",
        votes: { "1" => "999", "2" => "500" },
        stats: { eligible_voters: "90000", turnout: "50000", bad_ballots: "100",
                 no_vote: "200", counted_percent: "55.5" }
      }
      expect(zone.vote_results.sum(:votes)).to eq(1499)
      expect(zone.reload.zone_stat.counted_percent).to eq(55.5)
      rev = ResultRevision.where(source: "admin").last
      expect(rev.editor).to eq(admin.email_address)
    end

    it "allows decreasing votes (admin override)" do
      ResultWriter.new(zone, source: "api").apply!({ 1 => 1000 })
      patch admin_zone_result_path(zone), params: { confirm: "1", votes: { "1" => "900" } }
      expect(zone.vote_results.first.reload.votes).to eq(900)
    end

    it "toggles data mode between api and manual" do
      expect {
        patch toggle_mode_admin_election_path
      }.to change { election.reload.data_mode }.from("api").to("manual")
    end
  end
end
```

- [ ] **Step 2: รันให้ fail**

```bash
bundle exec rspec spec/requests/admin_spec.rb
```

Expected: FAIL — `undefined ... admin_root_path`

- [ ] **Step 3: Routes**

ใน `config/routes.rb` เพิ่ม:

```ruby
  namespace :admin do
    root "dashboard#index"
    resources :zone_results, only: %i[edit update]
    resource :election, only: [] do
      patch :toggle_mode
    end
    resources :revisions, only: :index
  end
```

- [ ] **Step 4: Controllers**

Create `app/controllers/admin/dashboard_controller.rb`:

```ruby
class Admin::DashboardController < ApplicationController
  def index
    @election = Election.current
    @zones = @election.zones.includes(:zone_stat).order(:code)
  end
end
```

Create `app/controllers/admin/zone_results_controller.rb`:

```ruby
class Admin::ZoneResultsController < ApplicationController
  def edit
    @zone = Election.current.zones.find(params[:id])
    @candidates = Election.current.candidates.order(:number)
    @stat = @zone.zone_stat || @zone.build_zone_stat
    @existing = @zone.vote_results.index_by(&:candidate_id)
  end

  def update
    election = Election.current
    zone = election.zones.find(params[:id])

    # spec §5.3: ทุกการแก้ต้อง confirm
    unless params[:confirm] == "1"
      return redirect_to edit_admin_zone_result_path(zone), alert: "ต้องติ๊กช่องยืนยันก่อนบันทึก"
    end

    votes = params.fetch(:votes, {}).permit!.to_h
      .transform_keys(&:to_i).transform_values(&:to_i)
    stats = params[:stats]&.permit(:eligible_voters, :turnout, :bad_ballots,
                                   :no_vote, :counted_percent)
      &.to_h&.symbolize_keys&.transform_values(&:to_f)

    changed = ResultWriter.new(zone, source: "manual",
                               editor: Current.user.email_address,
                               allow_decrease: true)
                          .apply!(votes, stats: stats)
    if changed
      ResultsBroadcaster.new(election).broadcast_all
      SnapshotPublisher.new(election).publish
    end
    redirect_to admin_root_path, notice: "บันทึกเขต#{zone.name} แล้ว"
  end
end
```

Create `app/controllers/admin/elections_controller.rb`:

```ruby
class Admin::ElectionsController < ApplicationController
  # โหมด manual: ingest หยุดเขียนทับ จนกว่าจะสลับกลับ (spec §5.3)
  def toggle_mode
    election = Election.current
    election.update!(data_mode: election.api? ? "manual" : "api")
    redirect_to admin_root_path, notice: "สลับโหมดข้อมูลเป็น #{election.data_mode} แล้ว"
  end
end
```

- [ ] **Step 5: Views**

Create `app/views/admin/dashboard/index.html.erb`:

```erb
<main class="wrap" style="display: block; max-width: 900px">
  <h1 style="font-family: var(--font-display); margin: 18px 0">ห้องควบคุมผลคะแนน</h1>

  <section class="card" style="padding: 16px 18px; margin-bottom: 16px">
    <p>โหมดข้อมูลปัจจุบัน:
      <strong style="color: <%= @election.api? ? 'var(--green)' : 'var(--dn-pink-deep)' %>">
        <%= @election.api? ? "API อัตโนมัติ" : "MANUAL — ทีมงานกรอกมือ (API ถูกพัก)" %>
      </strong>
    </p>
    <%= button_to @election.api? ? "สลับเป็นโหมดกรอกมือ (พัก API)" : "สลับกลับเป็นโหมด API",
          toggle_mode_admin_election_path, method: :patch,
          data: { turbo_confirm: "ยืนยันการสลับโหมดข้อมูล? มีผลต่อหน้าเว็บสาธารณะทันที" },
          style: "margin-top: 8px" %>
    <p style="margin-top: 8px"><%= link_to "ดูประวัติการแก้ไขทั้งหมด →", admin_revisions_path %></p>
  </section>

  <section class="card" style="padding: 16px 18px">
    <h2 style="font-family: var(--font-display); font-size: 17px">กรอก/แก้คะแนนรายเขต</h2>
    <table style="width: 100%; border-collapse: collapse; margin-top: 10px">
      <thead><tr>
        <th style="text-align: left; padding: 6px">เขต</th>
        <th style="text-align: right; padding: 6px">นับแล้ว</th>
        <th style="padding: 6px"></th>
      </tr></thead>
      <tbody>
        <% @zones.each do |zone| %>
          <tr style="border-top: 1px solid var(--line)">
            <td style="padding: 6px"><%= zone.code %> <%= zone.name %></td>
            <td style="padding: 6px; text-align: right"><%= zone.zone_stat&.counted_percent || 0 %>%</td>
            <td style="padding: 6px; text-align: right"><%= link_to "แก้ไข", edit_admin_zone_result_path(zone) %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </section>
</main>
```

Create `app/views/admin/zone_results/edit.html.erb`:

```erb
<main class="wrap" style="display: block; max-width: 640px">
  <h1 style="font-family: var(--font-display); margin: 18px 0">เขต<%= @zone.name %> (<%= @zone.code %>)</h1>

  <%= form_with url: admin_zone_result_path(@zone), method: :patch do |f| %>
    <section class="card" style="padding: 16px 18px; margin-bottom: 14px">
      <h2 style="font-family: var(--font-display); font-size: 16px">คะแนนผู้สมัคร</h2>
      <% @candidates.each do |c| %>
        <div style="display: flex; align-items: center; gap: 10px; margin-top: 8px">
          <label for="votes_<%= c.number %>" style="flex: 1">เบอร์ <%= c.number %> — <%= c.name %></label>
          <input type="number" min="0" id="votes_<%= c.number %>" name="votes[<%= c.number %>]"
                 value="<%= @existing[c.id]&.votes || 0 %>" style="width: 140px; padding: 6px">
        </div>
      <% end %>
    </section>

    <section class="card" style="padding: 16px 18px; margin-bottom: 14px">
      <h2 style="font-family: var(--font-display); font-size: 16px">สถิติเขต</h2>
      <% { eligible_voters: "ผู้มีสิทธิ", turnout: "มาใช้สิทธิ", bad_ballots: "บัตรเสีย",
           no_vote: "ไม่ประสงค์ฯ", counted_percent: "นับแล้ว (%)" }.each do |field, label| %>
        <div style="display: flex; align-items: center; gap: 10px; margin-top: 8px">
          <label for="stats_<%= field %>" style="flex: 1"><%= label %></label>
          <input type="number" min="0" step="<%= field == :counted_percent ? '0.1' : '1' %>"
                 id="stats_<%= field %>" name="stats[<%= field %>]"
                 value="<%= @stat.public_send(field) %>" style="width: 140px; padding: 6px">
        </div>
      <% end %>
    </section>

    <label style="display: flex; gap: 8px; align-items: center; margin-bottom: 12px">
      <input type="checkbox" name="confirm" value="1">
      ตรวจสอบตัวเลขแล้ว ยืนยันบันทึก (ลงประวัติในชื่อ <%= Current.user.email_address %>)
    </label>
    <%= f.submit "บันทึกผลเขตนี้" %>
    <%= link_to "ยกเลิก", admin_root_path, style: "margin-left: 10px" %>
  <% end %>
</main>
```

- [ ] **Step 6: รัน spec ให้ผ่าน + commit**

```bash
bundle exec rspec spec/requests/admin_spec.rb   # Expected: PASS
bundle exec rspec                                # ทั้ง suite ต้องเขียว
git add -A
git commit -m "feat: admin panel for manual results and api/manual mode toggle"
```

---

### Task 17: หน้าประวัติการแก้ไข (ResultRevision log)

**Files:**
- Test: เพิ่ม block ใน `spec/requests/admin_spec.rb`
- Create: `app/controllers/admin/revisions_controller.rb`, `app/views/admin/revisions/index.html.erb`

- [ ] **Step 1: เพิ่ม failing spec**

เพิ่มใน `spec/requests/admin_spec.rb` ใน describe "เมื่อ login แล้ว":

```ruby
    it "lists recent revisions" do
      ResultWriter.new(zone, source: "api").apply!({ 1 => 123 })
      get admin_revisions_path
      expect(response.body).to include("123")
      expect(response.body).to include("api")
    end
```

รัน: `bundle exec rspec spec/requests/admin_spec.rb` — Expected: FAIL (missing controller)

- [ ] **Step 2: Controller + view**

Create `app/controllers/admin/revisions_controller.rb`:

```ruby
class Admin::RevisionsController < ApplicationController
  def index
    @revisions = ResultRevision.includes(:recordable).order(created_at: :desc).limit(200)
  end
end
```

Create `app/views/admin/revisions/index.html.erb`:

```erb
<main class="wrap" style="display: block; max-width: 900px">
  <h1 style="font-family: var(--font-display); margin: 18px 0">ประวัติการแก้ไข (ล่าสุด 200 รายการ)</h1>
  <section class="card" style="padding: 16px 18px">
    <table style="width: 100%; border-collapse: collapse; font-size: 14px">
      <thead><tr>
        <th style="text-align: left; padding: 6px">เวลา</th>
        <th style="text-align: left; padding: 6px">รายการ</th>
        <th style="text-align: left; padding: 6px">เดิม → ใหม่</th>
        <th style="text-align: left; padding: 6px">ที่มา</th>
        <th style="text-align: left; padding: 6px">ผู้แก้</th>
      </tr></thead>
      <tbody>
        <% @revisions.each do |rev| %>
          <tr style="border-top: 1px solid var(--line)">
            <td style="padding: 6px"><%= rev.created_at.strftime("%d/%m %H:%M:%S") %></td>
            <td style="padding: 6px"><%= rev.recordable_type %> #<%= rev.recordable_id %></td>
            <td style="padding: 6px"><%= rev.old_values %> → <%= rev.new_values %></td>
            <td style="padding: 6px"><%= rev.source %></td>
            <td style="padding: 6px"><%= rev.editor || "-" %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
    <p style="margin-top: 10px; color: var(--muted)">
      ย้อนคะแนน: เปิดหน้าแก้ไขเขตนั้น กรอกค่า "เดิม" จากตารางนี้ แล้วบันทึก (ระบบบันทึกเป็น revision ใหม่ — ไม่ลบประวัติ)
    </p>
  </section>
</main>
```

- [ ] **Step 3: รัน spec ให้ผ่าน + commit**

```bash
bundle exec rspec spec/requests/admin_spec.rb
git add -A
git commit -m "feat: admin revisions audit log"
```

### Task 18: Production config + k6 load test + runbook

**Files:**
- Modify: `config/cable.yml`, `config/environments/production.rb`
- Create: `loadtest/ws.js`, `loadtest/poll.js`, `docs/runbook-election-night.md`

- [ ] **Step 1: ActionCable ผ่าน Redis ใน production**

แทนที่ block `production:` ใน `config/cable.yml` (Rails 8 default เป็น solid_cable —
spec เลือก Redis pub/sub ระหว่าง 2 instances):

```yaml
production:
  adapter: redis
  url: <%= ENV.fetch("REDIS_URL") %>
  channel_prefix: bkk2026_production
```

- [ ] **Step 2: production.rb**

เพิ่มใน `config/environments/production.rb` ภายใน `Rails.application.configure do`:

```ruby
  # WebSocket ผ่าน ALB — เสิร์ฟ /cable จาก app เดียวกัน
  config.action_cable.allowed_request_origins = [ENV.fetch("PUBLIC_ORIGIN", "https://election.dailynews.co.th")]
```

- [ ] **Step 3: รายการ ENV ที่ production ต้องมี**

บันทึกไว้ใน runbook (Step 5) — สรุป:

| ENV | ใช้ทำอะไร |
|---|---|
| `DATABASE_URL` | RDS PostgreSQL |
| `REDIS_URL` | ElastiCache — ActionCable pub/sub |
| `ECT_API_URL` | endpoint API กกต./พาร์ทเนอร์ |
| `SNAPSHOT_BUCKET` | S3 bucket ของ results.json (CloudFront ชี้มา) |
| `PUBLIC_ORIGIN` | origin ของเว็บ สำหรับ allowed_request_origins |
| `NEWS_FEED_URL` | RSS เว็บหลัก (มี default) |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | สร้าง admin user ครั้งแรก |
| `RAILS_MASTER_KEY` | credentials |

หมายเหตุ: ใน production หน้าเว็บ poll fallback จาก CloudFront — แก้ `urlValue` default
ของ fallback/trend-chart controller ไม่ต้อง เพราะ CloudFront ครอบ origin เดียวกัน
(`/results.json` ถูก route ไป S3 origin ใน CloudFront behavior)

- [ ] **Step 4: k6 scripts (spec §8.3 — ต้องผ่านก่อน 21 มิ.ย.)**

Create `loadtest/ws.js`:

```js
// 6,000 WebSocket subscribers ค้าง connection 10 นาที
// วิธีหา SIGNED_STREAM: เปิดหน้าเว็บ staging → view source →
//   <turbo-cable-stream-source signed-stream-name="..."> เอาค่านั้นมาใส่
// รัน: k6 run -e WS_URL=wss://staging.example/cable -e SIGNED_STREAM=xxx loadtest/ws.js
import ws from "k6/ws";
import { check } from "k6";

export const options = {
  scenarios: {
    subscribers: { executor: "ramping-vus", startVUs: 0,
      stages: [ { duration: "2m", target: 6000 }, { duration: "8m", target: 6000 } ] }
  }
};

export default function () {
  const res = ws.connect(__ENV.WS_URL, {}, socket => {
    socket.on("open", () => {
      socket.send(JSON.stringify({
        command: "subscribe",
        identifier: JSON.stringify({
          channel: "Turbo::StreamsChannel",
          signed_stream_name: __ENV.SIGNED_STREAM
        })
      }));
    });
    socket.setTimeout(() => socket.close(), 9.5 * 60 * 1000);
  });
  check(res, { "ws status 101": r => r && r.status === 101 });
}
```

Create `loadtest/poll.js`:

```js
// จำลอง client ฝั่ง fallback: 8,000 ครั้ง/10 วิ ≈ 800 req/s ใส่ results.json (ผ่าน CloudFront)
// รัน: k6 run -e POLL_URL=https://staging-cdn.example/results.json loadtest/poll.js
import http from "k6/http";
import { check } from "k6";

export const options = {
  scenarios: {
    pollers: { executor: "constant-arrival-rate", rate: 800, timeUnit: "1s",
      duration: "10m", preAllocatedVUs: 1000, maxVUs: 2000 }
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"],
    http_req_failed: ["rate<0.01"]
  }
};

export default function () {
  const res = http.get(__ENV.POLL_URL);
  check(res, { "status 200": r => r.status === 200 });
}
```

เกณฑ์ผ่าน (จาก spec §1, §8): WS 6,000 ต่อค้างได้โดย error <1%, broadcast ถึง client
ภายใน <5 วิ (วัดด้วยเปิด browser จริงระหว่างรัน k6 แล้วป้อนคะแนนผ่าน admin),
polling p95 <1 วิ, error <1%

- [ ] **Step 5: Runbook คืนเลือกตั้ง**

Create `docs/runbook-election-night.md`:

```markdown
# Runbook คืนเลือกตั้ง 28 มิ.ย. 2569

## ก่อนปิดหีบ (ก่อน 17:00)
- [ ] ตรวจ ENV ครบ (ดู plan Task 18 Step 3) ทั้ง 2 app instances
- [ ] `bin/rails db:seed` แล้ว — 50 เขต + รายชื่อผู้สมัครจริง + admin users
- [ ] Solid Queue ทำงาน: log มี `ingest_poll` ทุก 30 วิ
- [ ] เปิดหน้าเว็บผ่าน CloudFront — WS ต่อได้ (DevTools เห็น /cable 101)
- [ ] ทดสอบ admin: กรอกคะแนนเขตทดสอบ → หน้า public อัปเดต <5 วิ → ลบ/แก้กลับ

## ระหว่างนับคะแนน
- ดู log ingest: บรรทัด `[ingest] rejected` = API ส่งของเพี้ยน → ตรวจกับพาร์ทเนอร์
- **API ล่ม/ค้าง:** job retry เองด้วย backoff — ถ้าเกิน ~5 นาทีไม่ฟื้น:
  เข้า /admin → "สลับเป็นโหมดกรอกมือ" → ทีมข่าวกรอกจากแหล่งสำรอง
- **API ฟื้น:** ตรวจตัวเลข API ล่าสุด (เทียบกับที่กรอกมือ) → สลับกลับโหมด API
  (ระวัง: ถ้าตัวเลข API ต่ำกว่าที่กรอกมือ ingest จะ reject เขตนั้น — ถูกต้องแล้ว
  รอ API ตามทันหรือคงโหมด manual ต่อ)
- **กรอกผิด:** /admin/revisions ดูค่าเดิม → เปิดเขตนั้นกรอกค่าที่ถูก → บันทึก
- **เว็บช้า/WS เต็ม:** ไม่ต้องทำอะไร — client ตกไป polling CDN เอง (เช็คว่า
  results.json บน CloudFront อัปเดต: `curl -s <CDN>/results.json | jq .updated_at`)

## หลังปิดระบบ
- [ ] export ResultRevision เก็บเป็นหลักฐาน: `bin/rails runner 'puts ResultRevision.order(:id).to_json' > revisions-backup.json`
- [ ] สลับ election.status เป็น "closed"
```

- [ ] **Step 6: รันทุก spec รอบสุดท้าย + commit**

```bash
bundle exec rspec
git add -A
git commit -m "feat: production cable config, k6 load tests, election night runbook"
```

---

## Phase 5 — Containerize & Deploy (UAT/Prod)

### Task 19: Docker image + smoke test ด้วย docker compose

**Files:**
- Verify/Modify: `Dockerfile`, `.dockerignore`, `bin/docker-entrypoint` (Rails 8 generate ให้แล้วตอน `rails new` — ห้ามสร้างใหม่ถ้ามีอยู่)
- Modify: `config/database.yml` (production block)
- Create: `compose.uat.yml`

- [ ] **Step 1: ตรวจไฟล์ Docker ที่ Rails generate ให้**

```bash
ls Dockerfile .dockerignore bin/docker-entrypoint
```

Expected: มีครบ 3 ไฟล์ (Rails 8 สร้างให้ default) — ถ้ามีครบ **ไม่ต้องแก้ Dockerfile**

- [ ] **Step 2: จัด production database config**

Rails 8 default production ใช้ multi-database (primary/cache/queue/cable) สำหรับ solid stack
— เราใช้ Redis เป็น cable adapter แล้ว (Task 18) จึงเหลือ 3 ฐาน
แทนที่ block `production:` ใน `config/database.yml`:

```yaml
production:
  primary: &primary_production
    <<: *default
    url: <%= ENV["DATABASE_URL"] %>
  cache:
    <<: *primary_production
    database: bkk2026_production_cache
    migrations_paths: db/cache_migrate
  queue:
    <<: *primary_production
    database: bkk2026_production_queue
    migrations_paths: db/queue_migrate
```

(`url` + `database` ใช้ร่วมกันได้ — `database` override ชื่อฐานจาก url; `db:prepare`
ใน docker-entrypoint จะสร้างครบทุกฐานเอง)

- [ ] **Step 3: docker compose สำหรับ smoke test / UAT แบบ self-contained**

Create `compose.uat.yml`:

```yaml
# UAT/smoke test: ทุกอย่างในเครื่องเดียว — production จริงใช้ RDS/ElastiCache ผ่าน ENV
services:
  web:
    build: .
    ports:
      - "3000:80"
    environment:
      DATABASE_URL: postgres://postgres:secret@db/bkk2026_production
      REDIS_URL: redis://redis:6379/0
      RAILS_MASTER_KEY: ${RAILS_MASTER_KEY}
      SOLID_QUEUE_IN_PUMA: "1"          # รัน ingest job ใน puma — เครื่องเดียวพอสำหรับ UAT
      PUBLIC_ORIGIN: http://localhost:3000
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
  db:
    image: postgres:17
    environment:
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: bkk2026_production
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 2s
      retries: 15
  redis:
    image: redis:7
```

- [ ] **Step 4: Build + smoke test**

```bash
docker build -t bkk2026-election .
RAILS_MASTER_KEY=$(cat config/master.key) docker compose -f compose.uat.yml up -d
sleep 10
curl -fsS http://localhost:3000/up        # Expected: HTTP 200 (Rails health check)
curl -fsS http://localhost:3000/ | grep -o "เลือกตั้งผู้ว่าฯ"   # Expected: เจอข้อความ
docker compose -f compose.uat.yml down
```

ถ้า build/boot fail: อ่าน error แล้วแก้ตามจริง (ส่วนใหญ่คือ ENV ขาดหรือ database.yml) —
ห้าม comment ส่วนของ Dockerfile ทิ้งเพื่อให้ผ่าน

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: production docker image with UAT compose smoke test"
```

---

### Task 20: Kamal + GHCR + CI build

**Files:**
- Create: `config/deploy.yml`, `.kamal/secrets`, `.github/workflows/docker.yml`
- Modify: `Gemfile` (kamal), `docs/runbook-election-night.md` (วิธี deploy)

- [ ] **Step 1: ติดตั้ง Kamal**

```bash
bundle add kamal --group development --require false
bin/kamal init
```

Expected: สร้าง `config/deploy.yml` + `.kamal/secrets`

- [ ] **Step 2: เขียน deploy config**

แทนที่ `config/deploy.yml` (ค่าใน `< >` คือของจริงที่ทีมเติมตอน deploy — server IP/domain
ยังไม่รู้ตอนเขียนแผน):

```yaml
service: bkk2026-election
image: ghcr.io/<GITHUB_ORG>/bkk2026-election

servers:
  web:
    hosts:
      - <SERVER_IP>

proxy:
  ssl: true
  host: <ELECTION_DOMAIN>          # เช่น uat-election.dailynews.co.th

registry:
  server: ghcr.io
  username: <GITHUB_USERNAME>
  password:
    - KAMAL_REGISTRY_PASSWORD      # GitHub PAT scope write:packages — ใส่ใน .kamal/secrets

env:
  clear:
    SOLID_QUEUE_IN_PUMA: "1"
  secret:
    - RAILS_MASTER_KEY
    - DATABASE_URL
    - REDIS_URL
    - ECT_API_URL
    - SNAPSHOT_BUCKET
    - PUBLIC_ORIGIN
    - AWS_ACCESS_KEY_ID
    - AWS_SECRET_ACCESS_KEY

# UAT แบบไม่มี RDS: เปิด accessories ด้านล่างแล้วชี้ DATABASE_URL/REDIS_URL มาที่นี่
# accessories:
#   db:
#     image: postgres:17
#     host: <SERVER_IP>
#     env:
#       secret: [POSTGRES_PASSWORD]
#     directories: [data:/var/lib/postgresql/data]
#   redis:
#     image: redis:7
#     host: <SERVER_IP>
```

ตรวจ `.kamal/secrets` อยู่ใน `.gitignore` แล้ว (kamal init จัดให้ — ยืนยันอีกครั้ง)

- [ ] **Step 3: GitHub Actions — build + push image ขึ้น GHCR**

Create `.github/workflows/docker.yml`:

```yaml
name: Build and push image

on:
  push:
    branches: [main]
    tags: ["v*"]

permissions:
  contents: read
  packages: write

jobs:
  build-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=ref,event=tag
            type=sha
            type=raw,value=latest,enable={{is_default_branch}}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

(workflow จะทำงานเมื่อ repo ถูก push ขึ้น GitHub — ตอนนี้ repo ยังเป็น local อย่างเดียว
ตั้ง remote ก่อน: `git remote add origin git@github.com:<ORG>/<REPO>.git`)

- [ ] **Step 4: เพิ่มวิธี deploy ใน runbook**

ต่อท้าย `docs/runbook-election-night.md`:

```markdown
## Deploy ขึ้น UAT/Prod
1. push ขึ้น main (หรือ tag `v*`) → GitHub Actions build + push image ขึ้น GHCR อัตโนมัติ
2. เติมค่าใน `config/deploy.yml` (`<SERVER_IP>`, `<ELECTION_DOMAIN>`, org/username)
   และ secrets ใน `.kamal/secrets` (อย่า commit ค่าจริง)
3. ครั้งแรก: `bin/kamal setup` — ครั้งถัดไป: `bin/kamal deploy`
4. ตรวจ: `bin/kamal app logs -f` + เปิด https://<ELECTION_DOMAIN>/up ต้องได้ 200
5. seed production: `bin/kamal app exec 'bin/rails db:seed'` แล้วสร้าง admin user
   ตามคอมเมนต์ใน db/seeds.rb
```

- [ ] **Step 5: ตรวจ config + commit**

```bash
bin/kamal config   # Expected: แสดง config ที่ parse ได้ ไม่ error (ค่า <...> ยัง dummy ได้)
bundle exec rspec  # ทั้ง suite ยังเขียว
git add -A
git commit -m "feat: kamal deploy config and GHCR build workflow"
```

---

## ลำดับการทำงานแนะนำ (deadline 21 มิ.ย.)

| วัน | งาน |
|---|---|
| วันที่ 1 | Task 1-5 (foundation ทั้งหมด) |
| วันที่ 2 | Task 6-9 (data pipeline) |
| วันที่ 3-4 | Task 10-11 (dashboard + realtime — ชิ้นใหญ่สุด) |
| วันที่ 5 | Task 12-14 (chart, fallback, news) |
| วันที่ 6 | Task 15-17 (admin) |
| วันที่ 7 | Task 18-20 (prod config, Docker, Kamal/GHCR) + deploy UAT + k6 |
| วันที่ 8 | Dress rehearsal กับทีมข่าว (spec §8.4) — ซ้อม API ล่ม, สลับโหมด |
| วันที่ 9 | buffer แก้ของที่เจอจาก rehearsal |

**สิ่งที่แผนนี้ไม่ครอบ (ทำคู่ขนานโดยทีม infra):** ตั้ง AWS (ALB + EC2 ×2, RDS,
ElastiCache, S3 + CloudFront behavior `/results.json` → S3 origin, TTL 5 วิ),
DNS/TLS ของ election.dailynews.co.th — app พร้อม deploy ด้วย ENV ตาม Task 18 Step 3
