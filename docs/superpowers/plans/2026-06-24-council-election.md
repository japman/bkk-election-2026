# สก Council Election Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add the สก (bkk-council-2026) election as a second election alongside governor — per-district candidates, election-aware ingest, council snapshot, and a `/council` dashboard tab — reusing the governor pipeline.

**Architecture:** `Election.kind` (governor|council) + nullable `Candidate.zone_id` (สก candidates are scoped to one district). Reuse `Ingest::EctAdapter`, `Drive::FolderClient`, `VoteResult`, `ZoneStat`, `SnapshotArchiveJob`. Ingest/sync/snapshot are parameterized by election; a new `/council` tab presents the 50 single-member district races.

**Tech Stack:** Rails 8.1, RSpec, Solid Queue, Stimulus, webmock (test).

**Design spec:** `docs/superpowers/specs/2026-06-24-council-election-design.md`

## Global Constraints

- `Election.kind`: `"governor"` | `"council"`, default `"governor"`. `Election.governor` / `Election.council` = latest of that kind. `Election.current` stays as alias for `Election.governor`.
- `Candidate.zone_id` nullable. Governor candidates: `zone_id = nil` (election-wide). สก candidates: `zone_id` set. Partial unique indexes: `(election_id, number) WHERE zone_id IS NULL` and `(election_id, zone_id, number) WHERE zone_id IS NOT NULL` (drop the old plain `(election_id, number)` unique).
- Council results endpoint: `bkk-council-2026/auto?level=area`. Council candidates: `bkk-council-2026/auto/candidates` (PAGINATED — follow `pagination.hasMore`, each candidate has `areaNumber`, `number`, `id`, `name`, `party{name,color}`).
- Zone code = `format("%02d", area_number)`. สก candidate→zone via `areaNumber`. เบอร์ restarts per district.
- สก photos: Drive folder id `1KFXxX44NpaRTNH8pY6EtKxqw6bSPeJXY`, files `BKK-<zone 2-digit>-<num 2-digit>.png` → `public/images/council/<zone>/<number>.png`; `photo_url = /images/council/<zone>/<number>.png`.
- Reuse `Ingest::EctAdapter`, `Drive::FolderClient`, `VoteResult`, `ZoneStat`, `ResultRevision`, `SnapshotArchiveJob` — do NOT fork them. Governor behavior must stay unchanged (its specs keep passing).
- Same event-driven archiving as governor (poll → write → publish → emit `SnapshotArchiveJob`).
- TDD: failing test first. `rtk bundle exec rspec ...` (rtk = passthrough). Commit per task. Do NOT push. Tests that write under `public/images` use a tmp public dir.

---

### Task 1: Migration + Election/Candidate model for two election kinds

**Files:** Create migration(s); Modify `app/models/election.rb`, `app/models/candidate.rb`, `db/schema.rb` (auto); Test `spec/models/election_spec.rb` (create), `spec/models/candidate_spec.rb` (append).

**Interfaces:** Produces `Election.kind`, `Election.governor`, `Election.council`; `Candidate#zone_id`, `Candidate belongs_to :zone (optional)`; per-(zone,number) uniqueness for zone-scoped candidates.

- [ ] **Step 1: Failing tests**

```ruby
# spec/models/election_spec.rb
require "rails_helper"
RSpec.describe Election do
  it "selects the latest election of each kind" do
    gov = Election.create!(name: "G", election_date: Date.new(2026,6,28), kind: "governor")
    cou = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    expect(Election.governor).to eq(gov)
    expect(Election.council).to eq(cou)
    expect(Election.current).to eq(gov) # alias for governor
  end
end
```

```ruby
# spec/models/candidate_spec.rb  (append)
  it "allows the same number in different zones for council, but not twice in one zone" do
    e = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    z1 = e.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "ข", grid_col: 2, grid_row: 1)
    e.candidates.create!(number: 1, name: "a", color: "#111", zone: z1)
    expect { e.candidates.create!(number: 1, name: "b", color: "#222", zone: z2) }.not_to raise_error
    expect { e.candidates.create!(number: 1, name: "c", color: "#333", zone: z1) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
```

- [ ] **Step 2: Run, verify fail** — `rtk bundle exec rspec spec/models/election_spec.rb spec/models/candidate_spec.rb` → FAIL (no `kind`/`zone_id`).

- [ ] **Step 3: Generate migrations + edit**

```bash
rtk bundle exec rails g migration AddKindToElections kind:string
rtk bundle exec rails g migration AddZoneToCandidates zone:references
```
Edit `...add_kind_to_elections.rb`:
```ruby
class AddKindToElections < ActiveRecord::Migration[8.1]
  def change
    add_column :elections, :kind, :string, null: false, default: "governor"
  end
end
```
Edit `...add_zone_to_candidates.rb` (the generator adds the column+index for zone; we make it nullable and swap the uniqueness):
```ruby
class AddZoneToCandidates < ActiveRecord::Migration[8.1]
  def change
    add_reference :candidates, :zone, null: true, foreign_key: true
    remove_index :candidates, column: [ :election_id, :number ], name: "index_candidates_on_election_id_and_number"
    add_index :candidates, [ :election_id, :number ], unique: true,
              where: "zone_id IS NULL", name: "idx_candidates_election_number_governor"
    add_index :candidates, [ :election_id, :zone_id, :number ], unique: true,
              where: "zone_id IS NOT NULL", name: "idx_candidates_election_zone_number_council"
  end
end
```

- [ ] **Step 4: Models** — `app/models/election.rb`: add
```ruby
  scope :governor, -> { where(kind: "governor").order(created_at: :desc) }
  scope :council,  -> { where(kind: "council").order(created_at: :desc) }
  def self.governor = governor.first
  def self.council = council.first
```
and change `def self.current = order(created_at: :desc).first` to `def self.current = governor`.
`app/models/candidate.rb`: add `belongs_to :zone, optional: true` (after `belongs_to :election`). Remove the model-level `validates :number, uniqueness:` if present (DB enforces it now); keep `validates :number, presence:, numericality:` and `:name, :color, presence:`.

- [ ] **Step 5: Migrate + run** — `rtk bundle exec rails db:migrate && rtk bundle exec rails db:test:prepare && rtk bundle exec rspec spec/models` → PASS. Then full suite (governor specs must still pass).

- [ ] **Step 6: Commit** — `rtk git add -A && rtk git commit -m "Add Election.kind + Candidate.zone_id for council (per-district) candidates"`

---

### Task 2: Seed the council election + its 50 zones

**Files:** Modify `db/seeds.rb`; Test `spec/seeds_spec.rb` (create) OR a runner check. Use a spec.

**Interfaces:** Produces an `Election` (kind "council") with 50 zones (same names/grid as governor). Idempotent.

- [ ] **Step 1: Failing test** `spec/seeds_council_spec.rb`
```ruby
require "rails_helper"
RSpec.describe "council seed" do
  it "creates a council election with 50 zones" do
    load Rails.root.join("db/seeds.rb")
    c = Election.council
    expect(c).to be_present
    expect(c.zones.count).to eq(50)
    expect(c.zones.pluck(:code)).to include("01", "50")
    load Rails.root.join("db/seeds.rb") # idempotent
    expect(Election.where(kind: "council").count).to eq(1)
  end
end
```

- [ ] **Step 2: Run, verify fail** → FAIL (no council election).

- [ ] **Step 3: Implement** — in `db/seeds.rb`, after the governor seed, reuse the `ZONES` constant:
```ruby
council = Election.find_or_create_by!(name: "เลือกตั้งสมาชิกสภากรุงเทพมหานคร 2569", kind: "council") do |e|
  e.election_date = Date.new(2026, 6, 28)
  e.status = "scheduled"
end
ZONES.each_with_index do |(name, col, row), i|
  council.zones.find_or_create_by!(code: format("%02d", i + 1)) do |z|
    z.name = name; z.grid_col = col; z.grid_row = row
  end
end
```
(Set the existing governor election's `kind` explicitly to "governor" in its `find_or_create_by!` block if not already.)

- [ ] **Step 4: Run** → PASS. Full suite green.

- [ ] **Step 5: Commit** — `rtk git add db/seeds.rb spec/seeds_council_spec.rb && rtk git commit -m "Seed council election + 50 zones"`

---

### Task 3: `ResultWriter` finds candidates scoped to the zone

**Files:** Modify `app/services/result_writer.rb`; Test `spec/services/result_writer_spec.rb` (append or create).

**Interfaces:** `ResultWriter#apply!` resolves a candidate by number among `zone_id IN (NULL, this zone)` — works for governor (election-wide, nil) and council (per-zone).

- [ ] **Step 1: Failing test** `spec/services/result_writer_spec.rb`
```ruby
require "rails_helper"
RSpec.describe ResultWriter do
  it "writes votes to the zone-scoped candidate (council)" do
    e = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    z1 = e.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "ข", grid_col: 2, grid_row: 1)
    c1 = e.candidates.create!(number: 1, name: "z1c1", color: "#111", zone: z1)
    e.candidates.create!(number: 1, name: "z2c1", color: "#222", zone: z2) # same number, other zone
    ResultWriter.new(z1, source: "api").apply!({ 1 => 500 })
    expect(c1.vote_results.sum(:votes)).to eq(500)
  end
end
```

- [ ] **Step 2: Run, verify fail** — `rtk bundle exec rspec spec/services/result_writer_spec.rb` → FAIL (`find_by!` finds the wrong/ambiguous candidate or raises).

- [ ] **Step 3: Implement** — in `app/services/result_writer.rb` line ~36, change:
```ruby
    candidate = @zone.election.candidates.find_by!(number: number)
```
to:
```ruby
    candidate = @zone.election.candidates.where(zone_id: [ nil, @zone.id ]).find_by!(number: number)
```

- [ ] **Step 4: Run** → PASS. Full suite green (governor: candidates have zone_id nil → `[nil, zone.id]` still matches).

- [ ] **Step 5: Commit** — `rtk git add app/services/result_writer.rb spec/services/result_writer_spec.rb && rtk git commit -m "ResultWriter resolves zone-scoped candidates (council support)"`

---

### Task 4: `Ingest::Client` parameterized by election slug

**Files:** Modify `app/services/ingest/client.rb`; Test `spec/services/ingest/client_spec.rb` (append).

**Interfaces:** `Ingest::Client.fetch_results(slug = nil)` / `.fetch_candidates(slug = nil, page: 1)` — when `slug` given, builds the URL for that election against the base host; default keeps the governor `ECT_API_URL` behavior.

- [ ] **Step 1: Failing test** (append to `spec/services/ingest/client_spec.rb`)
```ruby
  it "fetches results for an explicit election slug" do
    ENV["ECT_API_TOKENS"] = "tok-a"
    stub_request(:get, "https://media.election.in.th/api/media/elections/bkk-council-2026/auto?level=area")
      .with(headers: { "Authorization" => "Bearer tok-a" })
      .to_return(status: 200, body: { success: true, data: { areas: [] } }.to_json)
    expect(described_class.fetch_results("bkk-council-2026")).to include("success" => true)
  end
```
(Keep the existing `around` ENV hook; add `ENV["ECT_API_BASE"]` default below.)

- [ ] **Step 2: Run, verify fail** → FAIL (wrong arity / URL).

- [ ] **Step 3: Implement** — in `app/services/ingest/client.rb`, derive a base host and accept a slug:
```ruby
      def fetch_results(slug = nil) = get("#{election_base(slug)}/auto?level=area")
      def fetch_candidates(slug = nil, page: 1) = get("#{election_base(slug)}/auto/candidates?page=#{page}")
```
and add:
```ruby
      # Governor uses ECT_API_URL (full election base). For another election, swap the
      # slug on the same host.
      def election_base(slug)
        base = ENV.fetch("ECT_API_URL")
        return base if slug.nil?
        base.sub(%r{/elections/[^/]+\z}, "/elections/#{slug}")
      end
```
Change the existing `get` calls in `fetch_results`/`fetch_candidates` to use the new forms above (the private `get(url)` is unchanged — it still follows redirects + UTF-8 is only for `list` in `Drive`, not here).

- [ ] **Step 4: Run** → PASS (new + existing client specs). Full suite green.

- [ ] **Step 5: Commit** — `rtk git add app/services/ingest/client.rb spec/services/ingest/client_spec.rb && rtk git commit -m "Parameterize Ingest::Client by election slug"`

---

### Task 5: `ect:sync_candidates` generalized to council (paginated, per-zone)

**Files:** Modify `lib/tasks/ect.rake`; Test `spec/tasks/ect_sync_candidates_spec.rb` (append).

**Interfaces:** `ect:sync_candidates` (governor, default) and `ect:sync_candidates[council]` — council pages through `/auto/candidates`, upserts per-zone candidates.

- [ ] **Step 1: Failing test** (append)
```ruby
  it "syncs council candidates per zone across pages" do
    council = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    council.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    council.zones.create!(code: "02", name: "ข", grid_col: 2, grid_row: 1)
    page1 = { success: true, data: { candidates: [
      { id: "u1", number: 1, areaNumber: 1, name: "A", party: { name: "P1", color: "#111" } }],
      pagination: { hasMore: true } } }
    page2 = { success: true, data: { candidates: [
      { id: "u2", number: 1, areaNumber: 2, name: "B", party: { name: "P2", color: "#222" } }],
      pagination: { hasMore: false } } }
    allow(Ingest::Client).to receive(:fetch_candidates).with("bkk-council-2026", page: 1).and_return(JSON.parse(page1.to_json))
    allow(Ingest::Client).to receive(:fetch_candidates).with("bkk-council-2026", page: 2).and_return(JSON.parse(page2.to_json))
    Rake::Task["ect:sync_candidates"].reenable
    Rake::Task["ect:sync_candidates"].invoke("council")
    z1c1 = council.zones.find_by(code: "01").then { |z| council.candidates.find_by(zone: z, number: 1) }
    expect(z1c1.external_id).to eq("u1")
    expect(council.candidates.where(number: 1).count).to eq(2) # one per zone
  end
```

- [ ] **Step 2: Run, verify fail** → FAIL (task ignores arg / not per-zone).

- [ ] **Step 3: Implement** — rewrite `lib/tasks/ect.rake` task to take a kind arg:
```ruby
namespace :ect do
  desc "Sync candidates from the ECT API (kind: governor|council)"
  task :sync_candidates, [ :kind ] => :environment do |_t, args|
    kind = args[:kind] || "governor"
    if kind == "council"
      election = Election.council or abort("No council election")
      slug = "bkk-council-2026"
      page = 1; total = 0
      loop do
        payload = Ingest::Client.fetch_candidates(slug, page: page)
        (payload.dig("data", "candidates") || []).each do |c|
          zone = election.zones.find_by(code: format("%02d", c["areaNumber"])) or next
          rec = election.candidates.find_or_initialize_by(zone: zone, number: c["number"])
          rec.update!(name: c["name"], party: c.dig("party", "name"),
                      color: c.dig("party", "color") || "#888888", external_id: c["id"])
          total += 1
        end
        break unless payload.dig("data", "pagination", "hasMore")
        page += 1
      end
      puts "[ect:sync_candidates] council: #{total} candidates across #{page} page(s)"
    else
      election = Election.governor or abort("No governor election")
      candidates = Ingest::Client.fetch_candidates.dig("data", "candidates") || []
      candidates.each do |c|
        rec = election.candidates.find_or_initialize_by(number: c["number"])
        rec.update!(name: c["name"], party: c.dig("party", "name"),
                    color: c.dig("party", "color") || "#888888", external_id: c["id"])
      end
      puts "[ect:sync_candidates] governor: #{candidates.size} candidates"
    end
  end
end
```
(Note: governor `fetch_candidates` with no slug keeps using `ECT_API_URL`. Council `find_or_initialize_by(zone:, number:)` sets `zone_id`.)

- [ ] **Step 4: Run** → PASS (council + the existing governor example — update the governor example to `.invoke` with no arg if needed). Full suite green.

- [ ] **Step 5: Commit** — `rtk git add lib/tasks/ect.rake spec/tasks/ect_sync_candidates_spec.rb && rtk git commit -m "Generalize ect:sync_candidates to council (paginated, per-zone)"`

---

### Task 6: `media:sync_candidate_images` council mode (per-zone subfolders)

**Files:** Modify `lib/tasks/media.rake`; Test `spec/tasks/media_sync_candidate_images_spec.rb` (append).

**Interfaces:** `media:sync_candidate_images[council]` — `BKK-<zone>-<num>.png` → `public/images/council/<zone>/<num>.png`; sets `photo_url` on the (zone, number) candidate.

- [ ] **Step 1: Failing test** (append; isolate to tmp public like the existing examples)
```ruby
  it "imports council photos into per-zone subfolders" do
    council = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    z = council.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    c = council.candidates.create!(number: 3, name: "x", color: "#111", zone: z)
    allow(Rails).to receive(:public_path).and_return(tmp_public)
    allow(Drive::FolderClient).to receive(:list).with(MediaSync::COUNCIL_FOLDER)
      .and_return([{ id: "p", name: "BKK-01-03.png" }, { id: "x", name: ".DS_Store" }])
    allow(Drive::FolderClient).to receive(:download).and_return(png)
    Rake::Task["media:sync_candidate_images"].reenable
    Rake::Task["media:sync_candidate_images"].invoke("council")
    expect(c.reload.photo_url).to eq("/images/council/01/3.png")
    expect(tmp_public.join("images/council/01/3.png").exist?).to be true
  end
```
(Add `let(:tmp_public)` + `after { FileUtils.remove_entry(tmp_public) if tmp_public.exist? }` mirroring the existing spec; `require "tmpdir"` already present.)

- [ ] **Step 2: Run, verify fail** → FAIL (task ignores kind / wrong path).

- [ ] **Step 3: Implement** — in `lib/tasks/media.rake`: add `COUNCIL_FOLDER = ENV.fetch("DRIVE_COUNCIL_FOLDER", "1KFXxX44NpaRTNH8pY6EtKxqw6bSPeJXY")` to `MediaSync`; make the task take `[:kind]`. For `council`:
```ruby
    election = Election.council or abort("No council election")
    count = 0
    Drive::FolderClient.list(MediaSync::COUNCIL_FOLDER).each do |f|
      m = f[:name].match(/\ABKK-(\d{2})-(\d{2})(\.[A-Za-z]+)\z/i) or next
      zone = election.zones.find_by(code: m[1]) or next
      number = m[2].to_i
      candidate = election.candidates.find_by(zone: zone, number: number) or next
      begin
        url = MediaSync.store(Drive::FolderClient.download(f[:id]), "council/#{m[1]}", number.to_s, m[3].downcase)
        candidate.update!(photo_url: url)
        count += 1
      rescue StandardError => e
        Rails.logger.error("[media] council photo #{f[:name]} failed: #{e.class}: #{e.message}")
      end
    end
    puts "[media] council: #{count} photos"
```
Wrap the existing governor logic under the default branch (`kind == "council" ? ... : <existing>`), keeping `MediaSync.store` (it already does `Rails.public_path.join("images", subdir)` so `subdir = "council/01"` yields `public/images/council/01/3.png`). The task signature becomes `task :sync_candidate_images, [ :kind ] => :environment`.

- [ ] **Step 4: Run** → PASS (council + existing governor example with no-arg invoke). Full suite green; confirm no stray files outside tmp.

- [ ] **Step 5: Commit** — `rtk git add lib/tasks/media.rake spec/tasks/media_sync_candidate_images_spec.rb && rtk git commit -m "media:sync_candidate_images council mode (per-zone subfolders)"`

---

### Task 7: Election-aware `IngestPollJob(kind)` + recurring entry

**Files:** Modify `app/jobs/ingest_poll_job.rb`, `config/recurring.yml`; Test `spec/jobs/ingest_poll_job_spec.rb` (append a council example).

**Interfaces:** `IngestPollJob.perform(kind = "governor")` resolves the election by kind, fetches that election's results, writes, publishes, and emits the archive event.

- [ ] **Step 1: Failing test** (append) — a council poll writes per-zone results.
```ruby
  it "ingests council results into per-zone candidates" do
    council = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    z = council.zones.create!(code: "40", name: "ก", grid_col: 1, grid_row: 1)
    c2 = council.candidates.create!(number: 2, name: "win", color: "#111", zone: z, external_id: "u2")
    ENV["ECT_API_URL"] = "https://media.election.in.th/api/media/elections/bkk-governor-2026"
    payload = { "success" => true, "data" => { "areas" => [
      { "area_number" => 40, "results" => [{ "candidate_id" => "u2", "votes" => 6000 }],
        "metadata" => { "total_eligible_voters" => 9000, "total_votes" => 6500, "invalid_votes" => 30,
                        "no_votes" => 10, "coverage_percentage" => 85.0 } }] }, "source" => { "selected" => "final" } }
    allow(Ingest::Client).to receive(:fetch_results).with("bkk-council-2026").and_return(payload)
    allow(SnapshotPublisher).to receive(:new).and_return(instance_double(SnapshotPublisher, publish: true))
    allow(ResultsBroadcaster).to receive(:new).and_return(instance_double(ResultsBroadcaster, broadcast_all: true))
    described_class.perform_now("council")
    expect(c2.vote_results.sum(:votes)).to eq(6000)
  end
```

- [ ] **Step 2: Run, verify fail** → FAIL (perform takes no arg / governor-only).

- [ ] **Step 3: Implement** — make `perform` take a kind and resolve election + slug:
```ruby
  SLUGS = { "governor" => nil, "council" => "bkk-council-2026" }.freeze

  def perform(kind = "governor")
    election = (kind == "council" ? Election.council : Election.governor)
    return if election.nil? || election.manual?
    if ENV["ECT_API_URL"].blank?
      Rails.logger.info("[ingest:#{kind}] ECT_API_URL not configured — skipping"); return
    end
    candidate_map = election.candidates.where.not(external_id: nil).pluck(:external_id, :number).to_h
    if candidate_map.empty?
      Rails.logger.warn("[ingest:#{kind}] no candidates synced — skipping"); return
    end
    raw = Ingest::Client.fetch_results(SLUGS.fetch(kind))
    src = raw["source"] || {}
    Rails.logger.info("[ingest:#{kind}] source=#{src['selected']} coverage=#{src['areasWithData']}/#{src['competitiveAreasTotal']}")
    parsed = Ingest::EctAdapter.parse(raw, expected_zone_codes: election.zones.pluck(:code), candidate_map: candidate_map)
    unless parsed.ok?
      Rails.logger.error("[ingest:#{kind}] rejected payload: #{parsed.errors.join('; ')}"); return
    end
    changed = false
    election.zones.find_each do |zone|
      data = parsed.data[zone.code] or next
      begin
        changed |= ResultWriter.new(zone, source: "api").apply!(data[:votes], stats: data[:stats])
      rescue ResultWriter::StaleVotesError => e
        Rails.logger.error("[ingest:#{kind}] #{e.message} — zone skipped")
      end
    end
    if changed
      begin ResultsBroadcaster.new(election).broadcast_all
      rescue StandardError => e; Rails.logger.error("[ingest:#{kind}] broadcast failed: #{e.class} #{e.message}") end
    end
    SnapshotPublisher.new(election).publish
    SnapshotArchiveJob.perform_later(election.id, Time.current.iso8601)
  end
```
Note `candidate_map` for council = `{uuid => number}` (number unique per zone, but the adapter only needs uuid→number; `ResultWriter` resolves the right per-zone candidate by `(zone, number)` from Task 3). The existing governor example (no-arg `perform_now`) still works.
`config/recurring.yml`: add under the same environment block as `ingest_poll`:
```yaml
  ingest_poll_council:
    class: IngestPollJob
    args: [ "council" ]
    schedule: every 30 seconds
```
(and set the existing `ingest_poll` to `args: [ "governor" ]` for clarity — optional, default covers it.)

- [ ] **Step 4: Run** → PASS (council + governor job specs). Full suite green.

- [ ] **Step 5: Commit** — `rtk git add app/jobs/ingest_poll_job.rb config/recurring.yml spec/jobs/ingest_poll_job_spec.rb && rtk git commit -m "Election-aware IngestPollJob(kind) + council recurring poll"`

---

### Task 8: Council snapshot payload (per-district winner + seats) + publisher key

**Files:** Modify `app/services/results_snapshot.rb`, `app/services/snapshot_publisher.rb`, `app/services/snapshot_archive_job.rb`; Test `spec/services/results_snapshot_spec.rb` (append).

**Interfaces:** `ResultsSnapshot.new(election)` emits a council-shaped payload when `election.kind == "council"`: top-level `seats: [{party, color, seats}]` and `districts: [{code, name, counted_percent, winner: {number,name,party,color,votes}, results: [...]}]`. `SnapshotPublisher.new(election)` writes `results.json` (governor) or `results-council.json` (council). `SnapshotArchiveJob` archives under a kind-specific key prefix.

- [ ] **Step 1: Failing test** (append)
```ruby
  it "builds a council payload with per-district winners and seats-by-party" do
    e = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    z = e.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    win = e.candidates.create!(number: 1, name: "W", party: "P1", color: "#111", zone: z)
    lose = e.candidates.create!(number: 2, name: "L", party: "P2", color: "#222", zone: z)
    VoteResult.create!(zone: z, candidate: win, votes: 600)
    VoteResult.create!(zone: z, candidate: lose, votes: 400)
    ZoneStat.create!(zone: z, eligible_voters: 2000, turnout: 1000, bad_ballots: 0, no_vote: 0, counted_percent: 90.0)
    json = described_class.new(e).as_json
    d = json[:districts].first
    expect(d[:winner]).to include(number: 1, party: "P1", votes: 600)
    expect(json[:seats]).to include(hash_including(party: "P1", seats: 1))
  end
```

- [ ] **Step 2: Run, verify fail** → FAIL (no council shape).

- [ ] **Step 3: Implement** — in `app/services/results_snapshot.rb`, branch on kind:
```ruby
  def as_json(*)
    @election.kind == "council" ? council_json : governor_json
  end
```
Rename the existing body to `governor_json`. Add:
```ruby
  def council_json
    districts = @election.zones.order(:code).includes(:zone_stat, vote_results: :candidate).map do |z|
      ranked = z.vote_results.sort_by { |r| -r.votes }
      w = ranked.first&.candidate
      { code: z.code, name: z.name, counted_percent: z.zone_stat&.counted_percent.to_f,
        winner: w && { number: w.number, name: w.name, party: w.party, color: w.color,
                       photo_url: w.photo_url, votes: ranked.first.votes },
        results: ranked.map { |r| { number: r.candidate.number, name: r.candidate.name,
                                    party: r.candidate.party, color: r.candidate.color,
                                    photo_url: r.candidate.photo_url, votes: r.votes } } }
    end
    seats = districts.map { |d| d[:winner] }.compact
            .group_by { |w| w[:party] }
            .map { |party, ws| { party: party, color: ws.first[:color], seats: ws.size } }
            .sort_by { |s| -s[:seats] }
    { updated_at: Time.current.iso8601, kind: "council",
      counted_percent: @election.counted_percent.to_f, seats: seats, districts: districts }
  end
```
`app/services/snapshot_publisher.rb`: derive the key from kind — change `KEY = "results.json"` usage to `key = @election.kind == "council" ? "results-council.json" : "results.json"` inside `publish` (both S3 and disk branches use `key`).
`app/services/snapshot_archive_job.rb`: prefix the archived key by kind so council archives don't collide — change the key to `"snapshots/#{election.kind}/#{at.strftime('%Y-%m-%d')}/#{at.strftime('%H%M%S')}.json"` and build the body from `ResultsSnapshot.new(election)` (already election-based). (Read the job; `election.kind` is available via the loaded election.)

- [ ] **Step 4: Run** → PASS. Full suite green (governor snapshot unchanged via `governor_json`).

- [ ] **Step 5: Commit** — `rtk git add app/services/results_snapshot.rb app/services/snapshot_publisher.rb app/services/snapshot_archive_job.rb spec/services/results_snapshot_spec.rb && rtk git commit -m "Council snapshot: per-district winners + seats; kind-keyed publish/archive"`

---

### Task 9: `/council` route + controller + shared tab nav

**Files:** Modify `config/routes.rb`, create `app/controllers/council_controller.rb`, create `app/views/council/show.html.erb`, create `app/views/shared/_election_tabs.html.erb`, modify `app/views/dashboard/show.html.erb` (add tabs); Test `spec/requests/council_spec.rb`.

**Interfaces:** `GET /council` renders the council dashboard for `Election.council`; both dashboards show a tab nav (ผู้ว่าฯ | สก).

- [ ] **Step 1: Failing test** `spec/requests/council_spec.rb`
```ruby
require "rails_helper"
RSpec.describe "Council dashboard", type: :request do
  it "renders the council page" do
    Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    get "/council"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("สก")
  end
end
```

- [ ] **Step 2: Run, verify fail** → FAIL (no route).

- [ ] **Step 3: Implement**
`config/routes.rb`: add `get "council" => "council#show"` near the root route.
`app/controllers/council_controller.rb`:
```ruby
class CouncilController < ApplicationController
  allow_unauthenticated_access
  def show
    @election = Election.council
  end
end
```
`app/views/shared/_election_tabs.html.erb`:
```erb
<nav class="election-tabs">
  <%= link_to "ผู้ว่าฯ", root_path, class: ("active" if current_page?(root_path)) %>
  <%= link_to "สก", council_path, class: ("active" if current_page?(council_path)) %>
</nav>
```
`app/views/council/show.html.erb`: a minimal shell (filled by Task 10/11):
```erb
<%= render "shared/election_tabs" %>
<h1>ผลเลือกตั้ง สก กรุงเทพมหานคร</h1>
<div id="council-dashboard" data-controller="council"></div>
```
Add `<%= render "shared/election_tabs" %>` near the top of `app/views/dashboard/show.html.erb`.

- [ ] **Step 4: Run** → PASS. Full suite green.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "Add /council route, controller, and shared election tabs"`

---

### Task 10: Council map (colored by winning party) + seats summary

**Files:** Modify `app/views/council/show.html.erb`, create `app/views/council/_map.html.erb` + `_seats.html.erb`, create `app/javascript/controllers/council_controller.js`, modify `app/assets/stylesheets/application.css`; Test: request spec asserts map + seats render.

**Interfaces:** Council page renders a 50-district cartogram (each tile colored by its winner's party color) and a seats-by-party summary, both driven by `results-council.json`.

- [ ] **Step 1: Failing test** (append to `spec/requests/council_spec.rb`)
```ruby
  it "renders the district map grid and a seats summary container" do
    c = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    c.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    get "/council"
    expect(response.body).to include('class="map-grid"')
    expect(response.body).to include("council-seats")
  end
```

- [ ] **Step 2: Run, verify fail** → FAIL.

- [ ] **Step 3: Implement** — server-render the initial map + seats from the DB (then `council_controller.js` refreshes from `results-council.json`, mirroring the governor fallback pattern).
`app/views/council/_map.html.erb` (reuse the governor cartogram structure; tile color = winner color):
```erb
<% zones = election.zones.includes(zone_stat: {}, vote_results: :candidate).sort_by(&:code) %>
<div id="council-map"><div class="map-grid">
  <% zones.each do |z|
       w = z.vote_results.max_by(&:votes)&.candidate %>
    <button class="tile" data-zone-code="<%= z.code %>" data-action="council#show"
            style="--c: <%= w&.color || '#C9CFD6' %>; grid-column: <%= z.grid_col %>; grid-row: <%= z.grid_row %>"
            aria-label="เขต<%= z.name %><%= " ผู้ชนะ #{w.name}" if w %>"><span><%= z.name %></span></button>
  <% end %>
</div></div>
```
`app/views/council/_seats.html.erb`:
```erb
<div class="council-seats" id="council-seats">
  <% seats = election.zones.filter_map { |z| z.vote_results.max_by(&:votes)&.candidate }
                    .group_by(&:party).transform_values(&:size).sort_by { |_, n| -n } %>
  <% seats.each do |party, n| %>
    <span class="seat-row"><i style="background: <%= election.candidates.find_by(party: party)&.color %>"></i><%= party %> <b><%= n %></b> ที่นั่ง</span>
  <% end %>
</div>
```
`app/views/council/show.html.erb`: render both:
```erb
<%= render "shared/election_tabs" %>
<h1>ผลเลือกตั้ง สก กรุงเทพมหานคร</h1>
<% if @election %>
  <div data-controller="council">
    <%= render "council/seats", election: @election %>
    <%= render "council/map", election: @election %>
    <%= render "council/zone_detail" %>  <%# added in Task 11 %>
  </div>
<% else %>
  <p>ยังไม่มีข้อมูลการเลือกตั้ง สก</p>
<% end %>
```
(For this task, omit the `zone_detail` render line; add it in Task 11.) `council_controller.js`: a minimal Stimulus controller with a `show(e)` that reads `data-zone-code` (zone detail wired in Task 11) — for now a stub that stores the code. CSS: reuse `.map-grid`/`.tile`; add `.council-seats`/`.seat-row` styling.

- [ ] **Step 4: Run** → PASS. Full suite green.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "Council district map (colored by winner) + seats-by-party summary"`

---

### Task 11: Council district detail panel (สก race per district)

**Files:** Create `app/views/council/_zone_detail.html.erb`, modify `app/javascript/controllers/council_controller.js`, modify `app/assets/stylesheets/application.css`; Test: covered by request spec (panel container present) + JS inspection.

**Interfaces:** Clicking a district opens a panel showing that district's สก race from `results-council.json` `districts[]`: candidates ranked (photo/party/votes/%), winner highlighted.

- [ ] **Step 1: Failing test** (append to `spec/requests/council_spec.rb`)
```ruby
  it "includes the district detail panel container" do
    Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    get "/council"
    expect(response.body).to include('data-council-target="panel"')
  end
```

- [ ] **Step 2: Run, verify fail** → FAIL.

- [ ] **Step 3: Implement**
`app/views/council/_zone_detail.html.erb`:
```erb
<div class="zone-detail" data-council-target="panel" aria-live="polite">
  <div class="zd-head">
    <h3 data-council-target="name"></h3>
    <span class="zd-counted num" data-council-target="counted"></span>
    <button type="button" class="zd-close" data-action="council#hide" aria-label="ปิด">✕</button>
  </div>
  <div data-council-target="rows"></div>
</div>
```
Add `<%= render "council/zone_detail" %>` to `council/show.html.erb` (inside the `data-controller="council"` div).
`app/javascript/controllers/council_controller.js`:
```javascript
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["panel", "name", "counted", "rows"]
  async show(e) {
    const code = e.currentTarget.dataset.zoneCode
    const res = await fetch("/results-council.json", { cache: "no-store" })
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
CSS: append `.zd-row.winner{ font-weight:700; background:color-mix(in srgb, var(--c,#0E7A3D) 10%, #fff); }` and reuse the existing `.zone-detail`/`.zd-*` styles.

- [ ] **Step 4: Run** → PASS. Full suite green. Confirm `council_controller.js` backticks/braces balanced.

- [ ] **Step 5: Commit** — `rtk git add -A && rtk git commit -m "Council district detail panel (per-district สก race)"`

---

## Self-Review

**Spec coverage:** kind+zone_id model & partial uniqueness (T1) ✓; council election+zones seed (T2) ✓; ResultWriter zone-scoped lookup (T3) ✓; Client slug param (T4) ✓; paginated per-zone candidate sync (T5) ✓; council photos per-zone subfolders (T6) ✓; election-aware ingest + recurring (T7) ✓; council snapshot (winners+seats) + kind-keyed publish/archive (T8) ✓; route+controller+tabs (T9) ✓; map-by-winner + seats (T10) ✓; district detail panel (T11) ✓; reuse EctAdapter/Drive::FolderClient/VoteResult/ZoneStat/SnapshotArchiveJob (constraints) ✓; governor unchanged (T1/T3/T7/T8 keep governor paths) ✓; rollout = migrate→seed→sync[council]→photos[council] (spec) ✓.

**Placeholder scan:** every step has complete code + expected outcome; no TBD. (T10's `council_controller.js` stub is completed in T11.)

**Type consistency:** `Election.governor/.council` (T1) used in T5/T7/T8/T9; `Candidate.zone_id`/`belongs_to :zone` (T1) used by T3 lookup, T5 sync, T6 photos; `ResultWriter` `[nil, zone.id]` lookup (T3) consumed by T7 ingest; `Ingest::Client.fetch_results(slug)`/`fetch_candidates(slug, page:)` (T4) used by T5/T7; `ResultsSnapshot` council `districts[]`/`seats[]` + `results-council.json` (T8) consumed by `council_controller.js` (T11) and the map/seats partials (T10); `SnapshotArchiveJob` kind-keyed (T8) emitted by T7.
