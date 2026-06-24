# Candidate Photos & Party Logos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import governor candidate photos + party logos from the public Google Drive folder into `public/images/`, persist their URLs on candidates, and render them in the leaderboard and zone-detail panel with letter-avatar fallback.

**Architecture:** A `Drive::FolderClient` lists/downloads files from a public Drive folder (no API key — `embeddedfolderview` + `uc?export=download`). A `rake media:sync_candidate_images` task uses it to download `BKK-0NN` photos (→ candidate number N) and party logos (filename ≈ party name), writes them under `public/images/`, and sets `candidate.photo_url` / `candidate.party_logo_url`. `ResultsSnapshot` exposes both URLs; views render `<img>` with graceful fallback.

**Tech Stack:** Rails 8.1, RSpec, webmock (test), Net::HTTP. No ActiveStorage, no libvips dependency (images stored in original format).

**Design spec:** `docs/superpowers/specs/2026-06-24-candidate-images-design.md`

## Global Constraints

- Drive access is key-less and public: list via `GET https://drive.google.com/embeddedfolderview?id=<folderId>#list`; download via `GET https://drive.google.com/uc?export=download&id=<fileId>`. UA header `Mozilla/5.0`.
- Verified folder IDs: governor photos `1wFbkHhM2YotcEmY045yLVN9JteMlFvpJ`; party logos `1Z01qgR20v2maDupmwWrgsECJN5UbOIgD`. (Council `1KFXxX44NpaRTNH8pY6EtKxqw6bSPeJXY` is out of scope — Sub-project B.)
- Governor photo filename → candidate number: `/\ABKK-(\d{3})\./i`, number = captured integer (leading zeros stripped). `BKK-007.png` → number 7.
- Party logo filename stem ≈ party name; skip non-images and `.DS_Store` / `Thumbs.db` (anything starting with `.` or matching `Thumbs.db`, or without an image extension `.png/.jpg/.jpeg/.webp`).
- Store images in **original format** under `public/images/candidates/<number>.<ext>` and `public/images/parties/<slug>.<ext>`. No format conversion (webp optimization is deferred). `<slug>` = the filename stem with spaces→`-` and lowercased.
- URLs are the single source of truth: the task sets `candidate.photo_url` (`/images/candidates/<number>.<ext>`) and `candidate.party_logo_url` (`/images/parties/<slug>.<ext>`); nil means "no image" → UI falls back. `ResultsSnapshot` never derives paths by convention.
- Party match: normalize both candidate.party and logo stems (strip, remove inner spaces, unicode NFC, downcase); a candidate matches a logo when one normalized string contains the other. Unmatched (e.g. independents) → `party_logo_url` stays nil; log it.
- Do NOT modify: ingest layer (`Ingest::*`, `IngestPollJob`, `ResultWriter`), council, snapshot-archive. Scope is images only.
- TDD: failing test first. Run via `rtk bundle exec rspec ...` (rtk = transparent passthrough). Commit per task. Do NOT push.
- Tests that write under `public/images/` MUST clean up the files they create (use test-only candidate numbers / an `after` hook).

---

### Task 1: Add `party_logo_url` to candidates

**Files:**
- Create: `db/migrate/<timestamp>_add_party_logo_url_to_candidates.rb`
- Modify: `db/schema.rb` (auto)
- Test: `spec/models/candidate_spec.rb` (append one example)

**Interfaces:**
- Produces: `candidates.party_logo_url` (string, nullable); `Candidate#party_logo_url`. (`photo_url` already exists.)

- [ ] **Step 1: Write the failing test** (append to `spec/models/candidate_spec.rb`)

```ruby
  it "stores a party_logo_url" do
    c = build_election(zones: 0, candidates: 1).candidates.first
    c.update!(party_logo_url: "/images/parties/prachachon.png")
    expect(c.reload.party_logo_url).to eq("/images/parties/prachachon.png")
  end
```

- [ ] **Step 2: Run, verify fail**

Run: `rtk bundle exec rspec spec/models/candidate_spec.rb -e party_logo_url`
Expected: FAIL (`unknown attribute 'party_logo_url'`).

- [ ] **Step 3: Generate & edit migration**

```bash
rtk bundle exec rails generate migration AddPartyLogoUrlToCandidates party_logo_url:string
```
The generated file should read:
```ruby
class AddPartyLogoUrlToCandidates < ActiveRecord::Migration[8.1]
  def change
    add_column :candidates, :party_logo_url, :string
  end
end
```

- [ ] **Step 4: Migrate + run**

Run: `rtk bundle exec rails db:migrate && rtk bundle exec rails db:test:prepare && rtk bundle exec rspec spec/models/candidate_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add db/migrate db/schema.rb spec/models/candidate_spec.rb
rtk git commit -m "Add party_logo_url to candidates"
```

---

### Task 2: `Drive::FolderClient` (key-less public-folder list + download)

**Files:**
- Create: `app/services/drive/folder_client.rb`, `spec/fixtures/drive/folder_list.html`
- Test: `spec/services/drive/folder_client_spec.rb`

**Interfaces:**
- Produces: `Drive::FolderClient.list(folder_id) -> Array<{ id:, name: }>` (array of hashes with string-ish symbol keys `:id`, `:name`); `Drive::FolderClient.download(file_id) -> String` (raw bytes); raises `Drive::FolderClient::Error` on non-2xx.

- [ ] **Step 1: Create the fixture** `spec/fixtures/drive/folder_list.html`

```html
<div class="flip-entry" id="entry-FILEID_AAA" tabindex="0" role="link">
  <div class="flip-entry-info">
    <a href="https://drive.google.com/file/d/FILEID_AAA/view"></a>
    <div class="flip-entry-title">BKK-007.png</div>
  </div>
</div>
<div class="flip-entry" id="entry-FILEID_BBB" tabindex="0" role="link">
  <div class="flip-entry-info">
    <a href="https://drive.google.com/file/d/FILEID_BBB/view"></a>
    <div class="flip-entry-title">.DS_Store</div>
  </div>
</div>
```

- [ ] **Step 2: Write the failing test** `spec/services/drive/folder_client_spec.rb`

```ruby
require "rails_helper"

RSpec.describe Drive::FolderClient do
  let(:fixture) { Rails.root.join("spec/fixtures/drive/folder_list.html").read }

  it "lists files (id + name) from a public folder" do
    stub_request(:get, "https://drive.google.com/embeddedfolderview?id=FOLDER123")
      .to_return(status: 200, body: fixture)
    files = described_class.list("FOLDER123")
    expect(files).to contain_exactly(
      { id: "FILEID_AAA", name: "BKK-007.png" },
      { id: "FILEID_BBB", name: ".DS_Store" }
    )
  end

  it "downloads file bytes" do
    stub_request(:get, "https://drive.google.com/uc?export=download&id=FILE9")
      .to_return(status: 200, body: "\x89PNG-bytes")
    expect(described_class.download("FILE9")).to eq("\x89PNG-bytes")
  end

  it "raises Error on a non-2xx list response" do
    stub_request(:get, "https://drive.google.com/embeddedfolderview?id=BAD")
      .to_return(status: 404, body: "nope")
    expect { described_class.list("BAD") }.to raise_error(Drive::FolderClient::Error, /404/)
  end
end
```

- [ ] **Step 3: Run, verify fail**

Run: `rtk bundle exec rspec spec/services/drive/folder_client_spec.rb`
Expected: FAIL (uninitialized constant `Drive::FolderClient`).

- [ ] **Step 4: Implement** `app/services/drive/folder_client.rb`

```ruby
require "net/http"

module Drive
  class FolderClient
    class Error < StandardError; end

    LIST_URL     = "https://drive.google.com/embeddedfolderview?id=%s"
    DOWNLOAD_URL = "https://drive.google.com/uc?export=download&id=%s"

    class << self
      # [{ id:, name: }] for a public folder, via the server-rendered embed view.
      def list(folder_id)
        html = get(format(LIST_URL, folder_id))
        html.scan(/id="entry-([A-Za-z0-9_-]{10,60})"[\s\S]{0,1500}?flip-entry-title">([^<]+)</)
            .map { |id, name| { id: id, name: name.strip } }
      end

      def download(file_id)
        get(format(DOWNLOAD_URL, file_id))
      end

      private

      def get(url)
        uri = URI(url)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                              open_timeout: 10, read_timeout: 30) do |http|
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "Mozilla/5.0"
          http.request(req)
        end
        raise Error, "HTTP #{res.code} from #{uri}" unless res.is_a?(Net::HTTPSuccess)
        res.body
      rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError => e
        raise Error, "#{e.class}: #{e.message}"
      end
    end
  end
end
```

- [ ] **Step 5: Run, verify pass**

Run: `rtk bundle exec rspec spec/services/drive/folder_client_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 6: Commit**

```bash
rtk git add app/services/drive/folder_client.rb spec/services/drive/folder_client_spec.rb spec/fixtures/drive/folder_list.html
rtk git commit -m "Add Drive::FolderClient for key-less public folder listing + download"
```

---

### Task 3: `rake media:sync_candidate_images`

**Files:**
- Create: `lib/tasks/media.rake`
- Test: `spec/tasks/media_sync_candidate_images_spec.rb`

**Interfaces:**
- Consumes: `Drive::FolderClient.list/download`, `Election.current`, `candidates.photo_url` / `party_logo_url`.
- Produces: rake task `media:sync_candidate_images` that writes `public/images/candidates/<number>.<ext>` + `public/images/parties/<slug>.<ext>` and sets the URL columns.

- [ ] **Step 1: Write the failing test** `spec/tasks/media_sync_candidate_images_spec.rb`

```ruby
require "rails_helper"
require "rake"

RSpec.describe "media:sync_candidate_images", type: :task do
  let!(:election) { build_election(zones: 0, candidates: 0) }
  let(:png) { "\x89PNG\r\n\x1a\nfake".b }

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "media:sync_candidate_images" }
  end
  before do
    election.candidates.create!(number: 7, name: "ก", color: "#111", party: "ประชาชน")
    election.candidates.create!(number: 8, name: "ข", color: "#222", party: "อิสระ")
    allow(Drive::FolderClient).to receive(:list).with(MediaSync::GOV_FOLDER)
      .and_return([{ id: "g7", name: "BKK-007.png" }, { id: "x", name: ".DS_Store" }])
    allow(Drive::FolderClient).to receive(:list).with(MediaSync::LOGO_FOLDER)
      .and_return([{ id: "l1", name: "ประชาชน.png" }, { id: "t", name: "Thumbs.db" }])
    allow(Drive::FolderClient).to receive(:download).and_return(png)
  end
  after do
    Rake::Task["media:sync_candidate_images"].reenable
    FileUtils.rm_f(Dir[Rails.public_path.join("images/candidates/7.*")])
    FileUtils.rm_f(Dir[Rails.public_path.join("images/parties/*.*")])
  end

  it "downloads the BKK photo, writes it, and sets photo_url for number 7" do
    Rake::Task["media:sync_candidate_images"].invoke
    c7 = election.candidates.find_by(number: 7)
    expect(c7.photo_url).to eq("/images/candidates/7.png")
    expect(File.exist?(Rails.public_path.join("images/candidates/7.png"))).to be true
  end

  it "matches the party logo and sets party_logo_url, skipping junk files" do
    Rake::Task["media:sync_candidate_images"].invoke
    expect(election.candidates.find_by(number: 7).party_logo_url).to eq("/images/parties/ประชาชน.png".then { |s| s }) # see slug note
    # independent party has no logo file → stays nil
    expect(election.candidates.find_by(number: 8).party_logo_url).to be_nil
    # junk skipped: no Thumbs.db / .DS_Store written
    expect(Dir[Rails.public_path.join("images/parties/*")].map { |f| File.basename(f) })
      .not_to include(".DS_Store", "Thumbs.db")
  end
end
```
Note on the slug: the party file `ประชาชน.png` has no spaces, so slug == `ประชาชน`; `party_logo_url` == `/images/parties/ประชาชน.png`. Adjust the expectation to the slug rule (spaces→`-`, downcase ASCII) — for `ประชาชน` it is unchanged.

- [ ] **Step 2: Run, verify fail**

Run: `rtk bundle exec rspec spec/tasks/media_sync_candidate_images_spec.rb`
Expected: FAIL (task / `MediaSync` not defined).

- [ ] **Step 3: Implement** `lib/tasks/media.rake`

```ruby
require "fileutils"

module MediaSync
  GOV_FOLDER  = ENV.fetch("DRIVE_GOV_FOLDER",  "1wFbkHhM2YotcEmY045yLVN9JteMlFvpJ")
  LOGO_FOLDER = ENV.fetch("DRIVE_LOGO_FOLDER", "1Z01qgR20v2maDupmwWrgsECJN5UbOIgD")
  IMAGE_EXT   = /\.(png|jpe?g|webp)\z/i

  module_function

  def normalize(str)
    str.to_s.unicode_normalize(:nfc).gsub(/\s+/, "").downcase
  end

  def slug(stem)
    stem.strip.gsub(/\s+/, "-").downcase
  end

  def store(bytes, subdir, stem, ext)
    dir = Rails.public_path.join("images", subdir)
    FileUtils.mkdir_p(dir)
    File.binwrite(dir.join("#{stem}#{ext}"), bytes)
    "/images/#{subdir}/#{stem}#{ext}"
  end
end

namespace :media do
  desc "Import governor candidate photos + party logos from the public Drive folder into public/images"
  task sync_candidate_images: :environment do
    election = Election.current or abort("No current election")

    # --- photos: BKK-0NN.<ext> -> candidate number N ---
    photos = 0
    Drive::FolderClient.list(MediaSync::GOV_FOLDER).each do |f|
      m = f[:name].match(/\ABKK-(\d{3})(\.[A-Za-z]+)\z/i) or next
      number = m[1].to_i
      candidate = election.candidates.find_by(number: number) or next
      begin
        url = MediaSync.store(Drive::FolderClient.download(f[:id]), "candidates", number.to_s, m[2].downcase)
        candidate.update!(photo_url: url)
        photos += 1
      rescue Drive::FolderClient::Error => e
        Rails.logger.error("[media] photo #{f[:name]} failed: #{e.message}")
      end
    end

    # --- logos: filename stem ~= party name ---
    logo_map = {} # normalized stem => url
    Drive::FolderClient.list(MediaSync::LOGO_FOLDER).each do |f|
      next if f[:name].start_with?(".") || f[:name] == "Thumbs.db"
      ext = f[:name][MediaSync::IMAGE_EXT] or next
      stem = File.basename(f[:name], ext)
      begin
        url = MediaSync.store(Drive::FolderClient.download(f[:id]), "parties", MediaSync.slug(stem), ext.downcase)
        logo_map[MediaSync.normalize(stem)] = url
      rescue Drive::FolderClient::Error => e
        Rails.logger.error("[media] logo #{f[:name]} failed: #{e.message}")
      end
    end

    matched = 0
    election.candidates.find_each do |c|
      np = MediaSync.normalize(c.party)
      key = logo_map.keys.find { |k| !np.empty? && (k.include?(np) || np.include?(k)) }
      if key
        c.update!(party_logo_url: logo_map[key]); matched += 1
      else
        Rails.logger.info("[media] no logo for party=#{c.party.inspect} (##{c.number})")
      end
    end

    puts "[media] #{photos} photos, #{logo_map.size} logos, #{matched} candidates matched to a logo"
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `rtk bundle exec rspec spec/tasks/media_sync_candidate_images_spec.rb`
Expected: PASS (2 examples). (`store` keeps the file stem `<number>` / `<slug>`; the spec's `7.png` and `ประชาชน.png` match.)

- [ ] **Step 5: Commit**

```bash
rtk git add lib/tasks/media.rake spec/tasks/media_sync_candidate_images_spec.rb
rtk git commit -m "Add media:sync_candidate_images rake task"
```

---

### Task 4: Expose photo/logo URLs in `ResultsSnapshot`

**Files:**
- Modify: `app/services/results_snapshot.rb`
- Test: `spec/services/results_snapshot_spec.rb` (create if absent)

**Interfaces:**
- Consumes: `candidates.photo_url`, `candidates.party_logo_url`.
- Produces: each `candidates[]` entry additionally has `photo_url:` and `party_logo_url:` (string or nil).

- [ ] **Step 1: Write the failing test** `spec/services/results_snapshot_spec.rb`

```ruby
require "rails_helper"

RSpec.describe ResultsSnapshot do
  it "includes photo_url and party_logo_url for each candidate" do
    e = build_election(zones: 1, candidates: 1)
    c = e.candidates.first
    c.update!(photo_url: "/images/candidates/1.png", party_logo_url: "/images/parties/x.png")
    entry = described_class.new(e).as_json[:candidates].first
    expect(entry).to include(photo_url: "/images/candidates/1.png", party_logo_url: "/images/parties/x.png")
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `rtk bundle exec rspec spec/services/results_snapshot_spec.rb`
Expected: FAIL (keys missing).

- [ ] **Step 3: Implement** — in `app/services/results_snapshot.rb`, extend the `candidates:` mapping. Replace the candidate hash:

```ruby
        { number: c.number, name: c.name, party: c.party, color: c.color,
          votes: c.total_votes.to_i,
          percent: total.zero? ? 0.0 : (c.total_votes * 100.0 / total).round(1) }
```
with:
```ruby
        { number: c.number, name: c.name, party: c.party, color: c.color,
          photo_url: c.photo_url, party_logo_url: c.party_logo_url,
          votes: c.total_votes.to_i,
          percent: total.zero? ? 0.0 : (c.total_votes * 100.0 / total).round(1) }
```

- [ ] **Step 4: Run, verify pass**

Run: `rtk bundle exec rspec spec/services/results_snapshot_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add app/services/results_snapshot.rb spec/services/results_snapshot_spec.rb
rtk git commit -m "Expose candidate photo_url and party_logo_url in results snapshot"
```

---

### Task 5: Render photos + party logos (leaderboard + zone detail) with fallback

**Files:**
- Modify: `app/views/dashboard/_leaderboard.html.erb`, `app/javascript/controllers/zone_detail_controller.js`, `app/assets/stylesheets/application.css`
- Test: `spec/views/dashboard/leaderboard_spec.rb` (view spec)

**Interfaces:**
- Consumes: `candidate.photo_url`, `candidate.party_logo_url` (leaderboard); `data.candidates[].photo_url`/`party_logo_url` from `results.json` (zone detail JS).

- [ ] **Step 1: Write the failing view test** `spec/views/dashboard/leaderboard_spec.rb`

```ruby
require "rails_helper"

RSpec.describe "dashboard/_leaderboard", type: :view do
  it "renders a photo img when photo_url is present, else a letter avatar" do
    e = build_election(zones: 0, candidates: 2)
    e.candidates.order(:number).first.update!(photo_url: "/images/candidates/1.png")
    # candidate 2 left without photo_url
    render partial: "dashboard/leaderboard", locals: { election: e }
    expect(rendered).to include('src="/images/candidates/1.png"')
    expect(rendered).to include('class="avatar"') # fallback letter avatar still present for the photo-less one
  end
end
```
(If `render partial` needs the election to expose `leaderboard`/`total_votes`, `build_election` already provides a persisted election with those methods.)

- [ ] **Step 2: Run, verify fail**

Run: `rtk bundle exec rspec spec/views/dashboard/leaderboard_spec.rb`
Expected: FAIL (no `<img src=...>` rendered yet).

- [ ] **Step 3: Update the leaderboard partial** — in `app/views/dashboard/_leaderboard.html.erb`, replace the avatar block:

```erb
        <div class="avatar"><%= c.name.first %></div>
```
with:
```erb
        <% if c.photo_url.present? %>
          <img class="avatar avatar-img" src="<%= c.photo_url %>" alt="<%= c.name %>" loading="lazy">
        <% else %>
          <div class="avatar"><%= c.name.first %></div>
        <% end %>
```
And add the party logo next to the party text. Replace:
```erb
        <div class="party">เบอร์ <%= c.number %> • <%= c.party %></div>
```
with:
```erb
        <div class="party">
          <% if c.party_logo_url.present? %><img class="party-logo" src="<%= c.party_logo_url %>" alt="" loading="lazy"><% end %>
          เบอร์ <%= c.number %> • <%= c.party %>
        </div>
```
Apply the same avatar change to any other place in this partial that renders `.avatar` (e.g. the table rows below the podium), using the identical if/else.

- [ ] **Step 4: Run, verify pass**

Run: `rtk bundle exec rspec spec/views/dashboard/leaderboard_spec.rb`
Expected: PASS.

- [ ] **Step 5: Add CSS** — append to `app/assets/stylesheets/application.css`:

```css
.avatar-img{ object-fit:cover; background:#fff; }
.party-logo{ width:18px; height:18px; border-radius:3px; object-fit:contain; vertical-align:-3px; margin-right:4px; }
.zd-photo{ width:28px; height:28px; border-radius:50%; object-fit:cover; flex:0 0 auto; }
```

- [ ] **Step 6: Update zone-detail JS** — in `app/javascript/controllers/zone_detail_controller.js`, change the row template to include a photo (with color-dot fallback) and party logo. Replace the `this.rowsTarget.innerHTML = ...` block's row return with:

```javascript
    return `<div class="zd-row">
      ${c.photo_url ? `<img class="zd-photo" src="${c.photo_url}" alt="" loading="lazy">` : `<i style="background:${c.color}"></i>`}
      <span class="zd-name">เบอร์ ${c.number} ${c.name}${c.party_logo_url ? ` <img class="party-logo" src="${c.party_logo_url}" alt="">` : ""}</span>
      <span class="zd-v num">${t.votes.toLocaleString("th-TH")} (${pct}%)</span>
    </div>`
```

- [ ] **Step 7: Verify suite + commit**

Run: `rtk bundle exec rspec`
Expected: PASS (no regressions).
```bash
rtk git add app/views/dashboard/_leaderboard.html.erb app/javascript/controllers/zone_detail_controller.js app/assets/stylesheets/application.css spec/views/dashboard/leaderboard_spec.rb
rtk git commit -m "Render candidate photos + party logos with letter-avatar fallback"
```

---

## Self-Review

**Spec coverage:** Drive::FolderClient key-less list+download (Task 2) ✓; party_logo_url column (Task 1) ✓; sync task with BKK-0NN→number, logo→party match, junk skipping, original-format storage, URL persistence (Task 3) ✓; snapshot exposes URLs (Task 4) ✓; leaderboard + zone-detail render with fallback + CSS (Task 5) ✓; verified folder IDs + mechanics in Global Constraints ✓; reuse-ready folder IDs via ENV (Task 3 `GOV_FOLDER`/`LOGO_FOLDER` ENV-overridable) ✓; rollout = run task locally, commit images, run once in prod (spec) ✓. Deviation from spec: original-format storage instead of webp (spec's documented fallback) — captured in Global Constraints; webp deferred.

**Placeholder scan:** every code/test step has complete code; commands have expected output; no TBD/TODO. (Task 3 Step 1 has an explanatory note on the slug expectation — the assertion value is concrete: `/images/parties/ประชาชน.png`.)

**Type consistency:** `Drive::FolderClient.list -> [{id:,name:}]` / `.download -> String` used identically in Task 3; `MediaSync::GOV_FOLDER`/`LOGO_FOLDER` referenced in the Task 3 spec and defined in the Task 3 rake module; `photo_url`/`party_logo_url` set in Task 3, read in Task 4 (snapshot) and Task 5 (views) with matching names; snapshot keys `photo_url:`/`party_logo_url:` consumed by the zone-detail JS (`c.photo_url`, `c.party_logo_url`).
