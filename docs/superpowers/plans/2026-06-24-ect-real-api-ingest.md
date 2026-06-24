# ECT Real-API Ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fictional ingest payload shape with the real ECT media API for `bkk-governor-2026` (per-area results + candidate UUID→number mapping + candidate sync).

**Architecture:** `rake ect:sync_candidates` pulls 18 candidates (storing each ECT UUID in `candidates.external_id`). `IngestPollJob` builds a UUID→number map from the DB, fetches `/auto?level=area` (50 districts × 18 candidates) with a bearer token, and `Ingest::EctAdapter` normalizes it into the existing `{ code => { votes:, stats: } }` shape that `ResultWriter` already consumes. Downstream (writer, broadcaster, snapshot, archive, UI) is unchanged.

**Tech Stack:** Rails 8.1, RSpec, Solid Queue, Net::HTTP, webmock (new, test-only), aws-sdk-s3 (existing).

**Design spec:** `docs/superpowers/specs/2026-06-24-ect-real-api-ingest-design.md`

## Global Constraints

- Canonical API surface only: `/auto/*` (never `/realtime/*` or `/final/*`; they 308-redirect and sunset 2026-07-01).
- Results endpoint: `GET {ECT_API_URL}/auto?level=area`. Candidates endpoint: `GET {ECT_API_URL}/auto/candidates`. `ECT_API_URL` = `https://media.election.in.th/api/media/elections/bkk-governor-2026`.
- Every API request sends header `Authorization: Bearer {ECT_API_TOKEN}`.
- Candidate identity across the API is `candidate_id` (UUID string); our model identity is `number` (integer). Map via persisted `candidates.external_id`.
- Adapter output shape MUST stay exactly `{ "01".."50" => { votes: { number => Integer }, stats: { eligible_voters:, turnout:, bad_ballots:, no_vote:, counted_percent: } } }` so `ResultWriter` is untouched.
- Stat field mapping (area `metadata` → our stats): `total_eligible_voters→eligible_voters`, `total_votes→turnout`, `invalid_votes→bad_ballots`, `no_votes→no_vote`, `coverage_percentage→counted_percent`.
- Zone code = `format("%02d", area_number)` (area_number is 1–50).
- Validation stays all-or-nothing: any error rejects the whole payload, writes nothing, returns errors for the job to log.
- Do NOT modify: `ResultWriter`, `ResultsBroadcaster`, `SnapshotPublisher`, `SnapshotArchiveJob`, `ZoneStat`/`VoteResult`/`Zone` models, `ResultsSnapshot`, UI.
- TDD: write the failing test first every task. Run via `rtk bundle exec rspec ...`. Commit after each task. Do NOT push.
- Real captured fixtures already committed: `spec/fixtures/ingest/ect_area_results.json` (50 areas) and `spec/fixtures/ingest/ect_candidates.json` (18 candidates).

---

### Task 1: Persist candidate `external_id`

**Files:**
- Create: `db/migrate/<timestamp>_add_external_id_to_candidates.rb`
- Modify: `app/models/candidate.rb`, `db/schema.rb` (auto-updated by migrate)
- Test: `spec/models/candidate_spec.rb`

**Interfaces:**
- Produces: `candidates.external_id` (string, nullable, partial-unique); `Candidate#external_id`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/candidate_spec.rb
require "rails_helper"

RSpec.describe Candidate do
  let(:election) { build_election(zones: 0, candidates: 1) }

  it "stores an external_id" do
    c = election.candidates.first
    c.update!(external_id: "uuid-abc")
    expect(c.reload.external_id).to eq("uuid-abc")
  end

  it "rejects a duplicate non-null external_id" do
    election.candidates.first.update!(external_id: "uuid-dup")
    dup = election.candidates.build(number: 99, name: "x", external_id: "uuid-dup")
    expect(dup).to be_invalid
    expect(dup.errors[:external_id]).to be_present
  end

  it "allows multiple null external_ids" do
    election.candidates.create!(number: 98, name: "a")
    election.candidates.create!(number: 97, name: "b")
    expect(election.candidates.where(external_id: nil).count).to be >= 2
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `rtk bundle exec rspec spec/models/candidate_spec.rb`
Expected: FAIL (`unknown attribute 'external_id'`).

- [ ] **Step 3: Generate and edit the migration**

```bash
rtk bundle exec rails generate migration AddExternalIdToCandidates external_id:string
```
Edit the generated file to:
```ruby
class AddExternalIdToCandidates < ActiveRecord::Migration[8.1]
  def change
    add_column :candidates, :external_id, :string
    add_index :candidates, :external_id, unique: true, where: "external_id IS NOT NULL"
  end
end
```

- [ ] **Step 4: Add the model validation**

In `app/models/candidate.rb`, add:
```ruby
validates :external_id, uniqueness: true, allow_nil: true
```

- [ ] **Step 5: Migrate (dev + test) and run tests**

Run: `rtk bundle exec rails db:migrate && rtk bundle exec rails db:test:prepare && rtk bundle exec rspec spec/models/candidate_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 6: Commit**

```bash
rtk git add db/migrate db/schema.rb app/models/candidate.rb spec/models/candidate_spec.rb
rtk git commit -m "Add external_id to candidates for ECT UUID mapping"
```

---

### Task 2: Rewrite `Ingest::Client` (bearer auth, two endpoints)

**Files:**
- Modify: `Gemfile` (add webmock to `:test`), `app/services/ingest/client.rb`, `spec/rails_helper.rb` (require webmock)
- Test: `spec/services/ingest/client_spec.rb`

**Interfaces:**
- Produces: `Ingest::Client.fetch_results -> Hash` (parsed `/auto?level=area` JSON); `Ingest::Client.fetch_candidates -> Hash` (parsed `/auto/candidates` JSON); raises `Ingest::Client::FetchError` on non-2xx, transport error, or invalid JSON.
- Consumes: `ENV["ECT_API_URL"]`, `ENV["ECT_API_TOKEN"]`.

- [ ] **Step 1: Add webmock (test gem)**

```bash
rtk bundle add webmock --group test --skip-install && rtk bundle install
```
In `spec/rails_helper.rb`, add near the top (after other requires):
```ruby
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: true)
```

- [ ] **Step 2: Write the failing test**

```ruby
# spec/services/ingest/client_spec.rb
require "rails_helper"

RSpec.describe Ingest::Client do
  BASE = "https://media.election.in.th/api/media/elections/bkk-governor-2026".freeze

  around do |ex|
    old_url = ENV["ECT_API_URL"]; old_tok = ENV["ECT_API_TOKEN"]
    ENV["ECT_API_URL"] = BASE; ENV["ECT_API_TOKEN"] = "test-token"
    ex.run
    ENV["ECT_API_URL"] = old_url; ENV["ECT_API_TOKEN"] = old_tok
  end

  it "fetches area results with bearer auth and parses JSON" do
    stub = stub_request(:get, "#{BASE}/auto?level=area")
      .with(headers: { "Authorization" => "Bearer test-token" })
      .to_return(status: 200, body: { success: true, data: { areas: [] } }.to_json)
    expect(described_class.fetch_results).to eq("success" => true, "data" => { "areas" => [] })
    expect(stub).to have_been_requested
  end

  it "fetches candidates" do
    stub_request(:get, "#{BASE}/auto/candidates")
      .with(headers: { "Authorization" => "Bearer test-token" })
      .to_return(status: 200, body: { success: true, data: { candidates: [] } }.to_json)
    expect(described_class.fetch_candidates).to include("success" => true)
  end

  it "raises FetchError on a non-success status (e.g. 403)" do
    stub_request(:get, "#{BASE}/auto?level=area").to_return(status: 403, body: "denied")
    expect { described_class.fetch_results }.to raise_error(Ingest::Client::FetchError, /403/)
  end

  it "raises FetchError on invalid JSON" do
    stub_request(:get, "#{BASE}/auto?level=area").to_return(status: 200, body: "not-json")
    expect { described_class.fetch_results }.to raise_error(Ingest::Client::FetchError, /JSON/)
  end
end
```

- [ ] **Step 3: Run test, verify it fails**

Run: `rtk bundle exec rspec spec/services/ingest/client_spec.rb`
Expected: FAIL (`fetch_results` undefined).

- [ ] **Step 4: Rewrite the client**

```ruby
# app/services/ingest/client.rb
require "net/http"
require "json"

module Ingest
  class Client
    class FetchError < StandardError; end

    class << self
      def fetch_results = get("/auto?level=area")
      def fetch_candidates = get("/auto/candidates")

      private

      def get(path)
        uri = URI("#{ENV.fetch('ECT_API_URL')}#{path}")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: 5, read_timeout: 10) do |http|
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{ENV.fetch('ECT_API_TOKEN')}"
          request["Accept"] = "application/json"
          http.request(request)
        end
        raise FetchError, "HTTP #{response.code} from #{uri}" unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise FetchError, "invalid JSON from #{uri}: #{e.message}"
      rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError => e
        raise FetchError, "#{e.class}: #{e.message}"
      end
    end
  end
end
```

- [ ] **Step 5: Run tests, verify pass**

Run: `rtk bundle exec rspec spec/services/ingest/client_spec.rb`
Expected: PASS (4 examples).

- [ ] **Step 6: Commit**

```bash
rtk git add Gemfile Gemfile.lock spec/rails_helper.rb app/services/ingest/client.rb spec/services/ingest/client_spec.rb
rtk git commit -m "Rewrite Ingest::Client: bearer auth + /auto results & candidates endpoints"
```

---

### Task 3: Rewrite `Ingest::EctAdapter` for the area payload

**Files:**
- Modify: `app/services/ingest/ect_adapter.rb`
- Test: `spec/services/ingest/ect_adapter_spec.rb`

**Interfaces:**
- Consumes: `Ingest::Client.fetch_results` Hash; a `candidate_map` `{ uuid_string => number }`.
- Produces: `Ingest::EctAdapter.parse(payload, expected_zone_codes:, candidate_map:) -> Result(data:, errors:)` where `data` is `{ "01".."50" => { votes: { number => Integer }, stats: { eligible_voters:, turnout:, bad_ballots:, no_vote:, counted_percent: } } }`; `Result#ok?`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/ingest/ect_adapter_spec.rb
require "rails_helper"

RSpec.describe Ingest::EctAdapter do
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_area_results.json").read) }
  let(:candidate_map) do
    JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_candidates.json").read)
        .dig("data", "candidates").to_h { |c| [c["id"], c["number"]] }
  end
  let(:zone_codes) { (1..50).map { |n| format("%02d", n) } }

  def parse(p) = described_class.parse(p, expected_zone_codes: zone_codes, candidate_map: candidate_map)

  it "normalizes the real 50-area payload" do
    result = parse(payload)
    expect(result).to be_ok
    expect(result.data.keys).to match_array(zone_codes)
    a46 = result.data["46"]
    expect(a46[:votes][7]).to eq(33913)
    expect(a46[:stats]).to eq(
      eligible_voters: 172765, turnout: 112117,
      bad_ballots: 2177, no_vote: 1089, counted_percent: 84.55
    )
  end

  it "rejects when success is not true" do
    expect(parse(payload.merge("success" => false))).not_to be_ok
  end

  it "rejects an unknown candidate_id" do
    payload["data"]["areas"][0]["results"][0]["candidate_id"] = "not-a-known-uuid"
    result = parse(payload)
    expect(result).not_to be_ok
    expect(result.errors.join).to match(/unknown candidate_id/)
  end

  it "rejects a missing area" do
    payload["data"]["areas"].pop
    expect(parse(payload).errors.join).to match(/missing areas/)
  end

  it "rejects a negative vote" do
    payload["data"]["areas"][0]["results"][0]["votes"] = -5
    expect(parse(payload).errors.join).to match(/non-negative integer/)
  end

  it "rejects counted_percent out of range" do
    payload["data"]["areas"][0]["metadata"]["coverage_percentage"] = 150
    expect(parse(payload).errors.join).to match(/coverage_percentage out of range/)
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `rtk bundle exec rspec spec/services/ingest/ect_adapter_spec.rb`
Expected: FAIL (signature/shape mismatch).

- [ ] **Step 3: Rewrite the adapter**

```ruby
# app/services/ingest/ect_adapter.rb
module Ingest
  # The single binding point to the ECT API payload shape.
  # Policy: any error rejects the whole payload and returns errors for the caller to log.
  class EctAdapter
    Result = Struct.new(:data, :errors) do
      def ok? = errors.empty?
    end

    class << self
      def parse(payload, expected_zone_codes:, candidate_map:)
        unless payload.is_a?(Hash) && payload["success"] == true
          return Result.new({}, [ "payload: success was not true" ])
        end
        areas = payload.dig("data", "areas")
        return Result.new({}, [ "payload: data.areas must be an array" ]) unless areas.is_a?(Array)

        errors = []
        data = {}
        codes = areas.map { |a| area_code(a) }
        missing = expected_zone_codes - codes.compact
        errors << "missing areas: #{missing.join(', ')}" if missing.any?
        unexpected = codes.compact - expected_zone_codes
        errors << "unexpected areas: #{unexpected.join(', ')}" if unexpected.any?
        errors << "area with missing area_number" if codes.any?(&:nil?)
        dupes = codes.compact.tally.select { |_, n| n > 1 }.keys
        errors << "duplicate areas: #{dupes.join(', ')}" if dupes.any?

        areas.each do |a|
          code = area_code(a)
          next if code.nil?
          area_errors = validate_area(a, candidate_map)
          if area_errors.any?
            errors.concat(area_errors.map { |m| "area #{code}: #{m}" })
          else
            data[code] = normalize(a, candidate_map)
          end
        end
        Result.new(data, errors)
      end

      private

      def area_code(a)
        n = a["area_number"]
        n.is_a?(Integer) ? format("%02d", n) : nil
      end

      def validate_area(a, candidate_map)
        errors = []
        results = a["results"]
        return [ "results must be an array" ] unless results.is_a?(Array)

        results.each do |r|
          uuid = r["candidate_id"]
          errors << "unknown candidate_id #{uuid}" unless candidate_map.key?(uuid)
          unless r["votes"].is_a?(Integer) && r["votes"] >= 0
            errors << "votes must be a non-negative integer (#{uuid})"
          end
        end

        meta = a["metadata"]
        return errors + [ "metadata must be a hash" ] unless meta.is_a?(Hash)
        pct = meta["coverage_percentage"]
        errors << "coverage_percentage out of range" unless pct.is_a?(Numeric) && pct.between?(0, 100)
        %w[total_eligible_voters total_votes invalid_votes no_votes].each do |f|
          errors << "#{f} must be a non-negative integer" unless meta[f].is_a?(Integer) && meta[f] >= 0
        end
        errors
      end

      def normalize(a, candidate_map)
        meta = a["metadata"]
        {
          votes: a["results"].to_h { |r| [ candidate_map.fetch(r["candidate_id"]), r["votes"] ] },
          stats: {
            eligible_voters: meta["total_eligible_voters"],
            turnout: meta["total_votes"],
            bad_ballots: meta["invalid_votes"],
            no_vote: meta["no_votes"],
            counted_percent: meta["coverage_percentage"]
          }
        }
      end
    end
  end
end
```

- [ ] **Step 4: Run tests, verify pass**

Run: `rtk bundle exec rspec spec/services/ingest/ect_adapter_spec.rb`
Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
rtk git add app/services/ingest/ect_adapter.rb spec/services/ingest/ect_adapter_spec.rb
rtk git commit -m "Rewrite Ingest::EctAdapter for the real /auto?level=area payload"
```

---

### Task 4: `rake ect:sync_candidates`

**Files:**
- Create: `lib/tasks/ect.rake`
- Test: `spec/tasks/ect_sync_candidates_spec.rb`

**Interfaces:**
- Consumes: `Ingest::Client.fetch_candidates`, `Election.current`.
- Produces: rake task `ect:sync_candidates` that upserts `Election.current.candidates` by `number` with `name`, `party` (=`party.name`), `color` (=`party.color`), `external_id` (=`id`).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/tasks/ect_sync_candidates_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "ect:sync_candidates", type: :task do
  let!(:election) { build_election(zones: 0, candidates: 0) }
  let(:cands) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_candidates.json").read) }

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "ect:sync_candidates" }
  end
  before { allow(Ingest::Client).to receive(:fetch_candidates).and_return(cands) }
  after  { Rake::Task["ect:sync_candidates"].reenable }

  it "upserts 18 candidates with external_id, party, and color" do
    Rake::Task["ect:sync_candidates"].invoke
    expect(election.candidates.count).to eq(18)
    c7 = election.candidates.find_by(number: 7)
    expect(c7.external_id).to eq("4ca853a4-c99e-39d9-a519-b5697be547f8")
    expect(c7.party).to eq("อิสระ")
    expect(c7.color).to eq("#888888")
  end

  it "is idempotent on re-run" do
    Rake::Task["ect:sync_candidates"].invoke
    Rake::Task["ect:sync_candidates"].reenable
    Rake::Task["ect:sync_candidates"].invoke
    expect(election.candidates.count).to eq(18)
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `rtk bundle exec rspec spec/tasks/ect_sync_candidates_spec.rb`
Expected: FAIL (task not defined).

- [ ] **Step 3: Write the rake task**

```ruby
# lib/tasks/ect.rake
namespace :ect do
  desc "Sync candidates (number/name/party/color/external_id) from the ECT API into Election.current"
  task sync_candidates: :environment do
    election = Election.current or abort("No current election")
    candidates = Ingest::Client.fetch_candidates.dig("data", "candidates") || []
    candidates.each do |c|
      record = election.candidates.find_or_initialize_by(number: c["number"])
      record.update!(
        name: c["name"],
        party: c.dig("party", "name"),
        color: c.dig("party", "color"),
        external_id: c["id"]
      )
    end
    message = "[ect:sync_candidates] upserted #{candidates.size} candidates"
    Rails.logger.info(message)
    puts message
  end
end
```

- [ ] **Step 4: Run tests, verify pass**

Run: `rtk bundle exec rspec spec/tasks/ect_sync_candidates_spec.rb`
Expected: PASS (2 examples). If `build_election` cannot create 0 candidates, pass the smallest it allows and adjust the count assertion to the post-sync total (still 18 distinct real numbers unless a seeded number collides — in that case assert `>= 18` and that number 7 has the external_id).

- [ ] **Step 5: Commit**

```bash
rtk git add lib/tasks/ect.rake spec/tasks/ect_sync_candidates_spec.rb
rtk git commit -m "Add ect:sync_candidates rake task"
```

---

### Task 5: Wire `IngestPollJob` to the real client/adapter

**Files:**
- Modify: `app/jobs/ingest_poll_job.rb`
- Test: `spec/jobs/ingest_poll_job_spec.rb` (rewrite the stubs/fixtures; keep existing behavioral coverage)

**Interfaces:**
- Consumes: `Ingest::Client.fetch_results`, `Ingest::EctAdapter.parse(payload, expected_zone_codes:, candidate_map:)`, `candidates.external_id`.
- Produces: same downstream effects as today (ResultWriter writes, broadcaster, `SnapshotPublisher#publish`, `SnapshotArchiveJob.perform_later`).

- [ ] **Step 1: Rewrite the job spec (failing)**

Replace the existing fetch/parse stubbing. The job now: builds `candidate_map` from `external_id`, calls `Ingest::Client.fetch_results` (returns a Hash), passes `candidate_map:` to the adapter. Seed candidates with external_ids that match the fixture so the map resolves.

```ruby
# spec/jobs/ingest_poll_job_spec.rb  (key changes)
require "rails_helper"

RSpec.describe IngestPollJob do
  let!(:election) { build_election(zones: 50, candidates: 0) }
  let(:area_payload) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_area_results.json").read) }
  let(:candidates_fixture) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_candidates.json").read) }
  let(:publisher) { instance_double(SnapshotPublisher, publish: true) }

  before do
    ENV["ECT_API_URL"] = "https://media.election.in.th/api/media/elections/bkk-governor-2026"
    # seed the 18 real candidates with external_ids so candidate_map resolves
    candidates_fixture.dig("data", "candidates").each do |c|
      election.candidates.create!(number: c["number"], name: c["name"],
                                  party: c.dig("party", "name"), color: c.dig("party", "color"),
                                  external_id: c["id"])
    end
    allow(Ingest::Client).to receive(:fetch_results).and_return(area_payload)
    allow(SnapshotPublisher).to receive(:new).and_return(publisher)
    allow(ResultsBroadcaster).to receive(:new)
      .and_return(instance_double(ResultsBroadcaster, broadcast_all: true))
  end

  it "writes per-area results and stats from the real payload, then publishes" do
    described_class.perform_now
    expect(election.zones.find_by(code: "46").vote_results.find_by(candidate: election.candidates.find_by(number: 7)).votes).to eq(33913)
    expect(election.zones.find_by(code: "46").zone_stat.counted_percent).to eq(84.55)
    expect(publisher).to have_received(:publish)
  end

  it "enqueues SnapshotArchiveJob after a successful poll" do
    expect { described_class.perform_now }
      .to have_enqueued_job(SnapshotArchiveJob).with(election.id, anything)
  end

  it "skips the poll when no candidates are synced (empty map)" do
    election.candidates.update_all(external_id: nil)
    expect(Ingest::Client).not_to receive(:fetch_results)
    described_class.perform_now
  end

  it "skips when ECT_API_URL is not configured" do
    ENV["ECT_API_URL"] = ""
    expect(Ingest::Client).not_to receive(:fetch_results)
    described_class.perform_now
  end
end
```
(Keep any still-relevant existing examples; delete ones asserting the old `zones`/`fetch`/`known_numbers` shape. Remove the obsolete `spec/fixtures/ingest/valid.json` if nothing else references it.)

- [ ] **Step 2: Run spec, verify it fails**

Run: `rtk bundle exec rspec spec/jobs/ingest_poll_job_spec.rb`
Expected: FAIL (job still calls `Ingest::Client.fetch` / `known_numbers`).

- [ ] **Step 3: Update the job**

```ruby
# app/jobs/ingest_poll_job.rb
class IngestPollJob < ApplicationJob
  queue_as :default
  retry_on Ingest::Client::FetchError, wait: 5.seconds, attempts: 2

  def perform
    election = Election.current
    return if election.nil? || election.manual?

    if ENV["ECT_API_URL"].blank?
      Rails.logger.info("[ingest] ECT_API_URL not configured — skipping poll")
      return
    end

    candidate_map = election.candidates.where.not(external_id: nil).pluck(:external_id, :number).to_h
    if candidate_map.empty?
      Rails.logger.warn("[ingest] no candidates synced (run rake ect:sync_candidates) — skipping poll")
      return
    end

    raw = Ingest::Client.fetch_results
    src = raw["source"] || {}
    Rails.logger.info("[ingest] source=#{src['selected']} coverage=#{src['areasWithData']}/#{src['competitiveAreasTotal']}")

    parsed = Ingest::EctAdapter.parse(
      raw,
      expected_zone_codes: election.zones.pluck(:code),
      candidate_map: candidate_map
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

    if changed
      begin
        ResultsBroadcaster.new(election).broadcast_all
      rescue StandardError => e
        Rails.logger.error("[ingest] broadcast failed: #{e.class} #{e.message}")
      end
    end

    SnapshotPublisher.new(election).publish
    SnapshotArchiveJob.perform_later(election.id, Time.current.iso8601)
  end
end
```

- [ ] **Step 4: Run the job spec + full suite, verify pass**

Run: `rtk bundle exec rspec spec/jobs/ingest_poll_job_spec.rb && rtk bundle exec rspec`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
rtk git add app/jobs/ingest_poll_job.rb spec/jobs/ingest_poll_job_spec.rb
rtk git rm --ignore-unmatch spec/fixtures/ingest/valid.json
rtk git commit -m "Wire IngestPollJob to real ECT client/adapter with candidate map"
```

---

### Task 6: Config & secrets wiring

**Files:**
- Modify: `.kamal/secrets`, `config/deploy.yml`
- (Operational, no automated test — verify config validity only.)

**Interfaces:**
- Produces: `ECT_API_TOKEN` available to the container env; `ECT_API_URL` set to the base election URL.

- [ ] **Step 1: Reference the token in `.kamal/secrets`**

Add after the existing app-config secrets:
```bash
ECT_API_TOKEN=$(bin/rails credentials:fetch kamal.ect_api_token)
```
(`ECT_API_URL` is already referenced in `.kamal/secrets` — leave its reference; its value is set in credentials.)

- [ ] **Step 2: Add `ECT_API_TOKEN` to `deploy.yml` env.secret**

In `config/deploy.yml` under `env: secret:`, add a line:
```yaml
    - ECT_API_TOKEN
```

- [ ] **Step 3: Verify config validity**

Run: `ruby -ryaml -e 'YAML.safe_load_file("config/deploy.yml", aliases: true); puts "deploy.yml OK"'`
Expected: `deploy.yml OK`.
(The real `kamal.ect_api_token` value and the `kamal.ect_api_url` base URL are set by the operator at rollout via `rails credentials:edit` — see the spec's Rollout section; not part of this commit.)

- [ ] **Step 4: Commit**

```bash
rtk git add .kamal/secrets config/deploy.yml
rtk git commit -m "Wire ECT_API_TOKEN secret into Kamal config"
```

---

## Self-Review

**Spec coverage:** migration+external_id (Task 1) ✓; Client auth+two endpoints (Task 2) ✓; Adapter area parse+mapping+validation (Task 3) ✓; sync task (Task 4) ✓; IngestPollJob wiring + map + source log + empty-map guard (Task 5) ✓; ECT_API_TOKEN/ECT_API_URL config (Task 6) ✓; downstream untouched (constraint enforced across tasks) ✓; fixtures committed ✓; rollout = operator sets token + runs sync (spec) ✓.

**Placeholder scan:** every code/test step contains complete code; commands have expected output; no TBD/TODO.

**Type consistency:** `fetch_results`/`fetch_candidates` return Hash (Task 2) and are consumed as Hash by Adapter/Job (Tasks 3, 5); `parse(payload, expected_zone_codes:, candidate_map:)` signature identical in Tasks 3 and 5; output `{ code => { votes:, stats: } }` consumed unchanged by `ResultWriter`; stat keys (`eligible_voters/turnout/bad_ballots/no_vote/counted_percent`) match `ResultWriter::STAT_FIELDS`.
