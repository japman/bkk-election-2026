# Design: สก council election (Sub-project B)

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan
**Scope:** Add the Bangkok Metropolitan Council (สก / bkk-council-2026) election as a second election alongside the governor race, with its own ingest, candidates (per-district), photos, snapshot, and a dedicated dashboard tab. Reuses the existing governor pipeline as much as possible.

## Problem

The app currently models a single election (governor, city-wide, 18 candidates, one winner). The สก election is structurally different: **50 independent single-member district races** — each เขต elects ONE councillor from its own ~3–10 candidates. We need to ingest, store, and present สก results without disturbing the governor experience.

## Verified data (live-checked 2026-06-24)

- **Results:** `GET …/elections/bkk-council-2026/auto?level=area` → identical envelope/shape to governor: `data.areas[]` (50), each `{ area_number, results: [{candidate_id(UUID), votes, percentage}], metadata: {good_votes,total_votes,invalid_votes,no_votes,coverage_percentage,total_eligible_voters,…} }`. **But each area's candidate set is its own** (e.g. area 40 had 4 candidates). One winner per area (top votes).
- **Candidates:** `GET …/bkk-council-2026/auto/candidates` is **paginated** (`data.candidates` + `pagination{page,limit,total,totalPages,hasMore}`, ~262 total). Each candidate has `id`(UUID), `number` (restarts per district), `areaNumber` (maps to เขต), `name`, `party{name,color}`, `rank`, `totalVotes`. `areaNumber` is set on every council candidate.
- **Photos:** Drive subfolder `ภาพ ส.ก.` (id `1KFXxX44NpaRTNH8pY6EtKxqw6bSPeJXY`), 258 files named `BKK-<zone 2-digit>-<number 2-digit>.png` (e.g. `BKK-01-03.png` = เขต 01, เบอร์ 3).
- **Sheet** (gid=0): 262 rows confirm ~5 candidates/district, 10 parties.

## Model decision (approved): reuse Election, scope candidates per zone

- `Election` gains `kind:string` (`"governor"` | `"council"`, default `"governor"`).
- `Candidate` gains `zone_id:bigint` (nullable FK → zones). Governor candidates: `zone_id = nil` (compete election-wide). สก candidates: `zone_id` set (compete only in their district).
- Uniqueness via **partial unique indexes**: `(election_id, number) WHERE zone_id IS NULL` (governor) and `(election_id, zone_id, number) WHERE zone_id IS NOT NULL` (council). (สก เบอร์ 1 exists in every district — only unique within a district.)
- `VoteResult`, `ZoneStat`, `ResultRevision`, `Ingest::EctAdapter`, `Drive::FolderClient` are **reused**.

## Architecture & data flow

```
SEED: a council Election (kind:"council") + its own 50 Zone rows (same เขต names/grid as governor)

rake ect:sync_candidates[council]   (paginates /auto/candidates)
  └─ upsert per-zone Candidate: zone = by areaNumber, number, name, party, color, external_id, zone_id

rake media:sync_candidate_images[council]   (reuses Drive::FolderClient)
  └─ BKK-<zone>-<num>.png → public/images/council/<zone>/<num>.png; set candidate.photo_url

Council ingest (recurring 30s, election-aware):
  fetch bkk-council-2026 /auto?level=area
   → Ingest::EctAdapter.parse(…, candidate_map: {uuid=>number for the council election})
   → per zone: ResultWriter (scoped to zone for council) writes VoteResult/ZoneStat
   → ResultsSnapshot(council).publish → results-council.json   (+ SnapshotArchiveJob event → S3, like governor)
   → ResultsBroadcaster(council) (its own Turbo stream)

UI: governor dashboard (existing, `/`) + new council tab (`/council`)
```

## Components

### 1. Migration + model
`add_kind_to_elections` (string, default "governor", not null) + `add_zone_id_to_candidates` (nullable FK + the two partial unique indexes; drop the old plain `(election_id, number)` unique). `Election`: `scope :governor`, `scope :council` + `Election.governor` / `Election.council` (latest of each kind). `Candidate`: `belongs_to :zone, optional: true`; validations adjusted (number presence; uniqueness handled by DB).

### 2. Election selection (coexistence)
Replace `Election.current` usage in the governor dashboard/ingest/snapshot with `Election.governor`; the council controller/ingest uses `Election.council`. **Decision:** keep `Election.current` as an alias for `Election.governor` (least churn, preserves existing specs) rather than removing it. Both elections coexist; selection is always by `kind`, never by "latest overall".

### 3. Seed (`db/seeds.rb`)
Create the council `Election` (kind "council") and its 50 `Zone` rows reusing the governor `ZONES` constant (same names + grid_col/grid_row). Idempotent (`find_or_create_by`). Candidates are NOT seeded (synced from the API).

### 4. Candidate sync — generalize `ect:sync_candidates`
Make the task take an election (governor default, or `council`). For council: page through `/auto/candidates` (follow `pagination.hasMore`), and for each candidate upsert into the council election by `(zone, number)` where `zone = council_election.zones.find_by(code: format("%02d", areaNumber))`, setting `name`, `party = party.name`, `color = party.color`, `external_id = id`, `zone_id`. The `Ingest::Client` gains an election-id parameter (or a council base URL) so both elections can be fetched.

### 5. Photos — generalize `media:sync_candidate_images`
Add a council mode: list the `ภาพ ส.ก.` folder, match `/\ABKK-(\d{2})-(\d{2})\.../` → zone code + number, write `public/images/council/<zone>/<number>.png`, and set `photo_url = /images/council/<zone>/<number>.png` on the matching per-zone candidate. Reuse `Drive::FolderClient` (already follows redirects + UTF-8). Committed as deploy artifact.

### 6. Ingest — election-aware
Generalize the governor `IngestPollJob` to take a kind: `IngestPollJob.perform(kind = "governor")` (default keeps existing call-sites/specs working). It resolves the election (`Election.governor`/`.council`), builds that election's candidate map, fetches its `/auto?level=area`, runs `Ingest::EctAdapter.parse`, and writes via `ResultWriter`. Two `recurring.yml` entries pass `"governor"` and `"council"`. **`ResultWriter` change:** when the zone's election is council (zone-scoped candidates), find the candidate by `(zone, number)` instead of `(election, number)`. This is the only ingest-internal change; the adapter is unchanged. Governor behavior is untouched.

### 7. Snapshot + broadcast — parameterized
`ResultsSnapshot.new(election)` already takes an election; add a council-shaped payload: per-district `{ winner: {number,name,party,party_color,votes}, counted_percent, results: [...] }`, plus a top-level `seats: [{party, color, seats}]` (count of district winners per party). `SnapshotPublisher.new(election, key:)` writes `results.json` (governor) or `results-council.json` (council). `SnapshotArchiveJob` is emitted for council too (its own archive key). `ResultsBroadcaster` broadcasts council regions on a separate Turbo stream.

### 8. UI — council tab
- Route `GET /council` (+ keep `/` governor). A shared tab nav (`ผู้ว่าฯ | สก`) on both.
- **Council dashboard:** a 50-district cartogram map colored by **winning party** (per district), a **seats-by-party** summary bar/list, and a click-to-open district panel showing that district's สก race (candidates ranked with photo/party/votes/%, winner highlighted). Reuse `_map_grid` / zone-detail / leaderboard patterns parameterized by election + a per-district "winner/seats" model rather than a single city leaderboard.
- The frontend reads `results-council.json` (live publish + fallback poll), mirroring governor.

### 9. Recurring
`config/recurring.yml`: add a council ingest entry (every 30s), alongside the governor one.

## Error handling
- Per-zone independence: a bad area rejects the whole council payload (all-or-nothing, as governor) and is logged; nothing partial is written.
- Empty council candidate map (sync not run) → skip the poll with a logged warning (same guard as governor).
- Missing photo/logo → letter-avatar / no-logo fallback (Sub-project A behavior).
- Council snapshot/archive failures isolated from governor (separate jobs/keys).

## Testing (RSpec)
- Migration/model: `Election.governor`/`.council` select by kind; per-zone candidate uniqueness (เบอร์ 1 allowed in two different zones; rejected twice in the same zone); governor uniqueness preserved.
- `ect:sync_candidates[council]`: paginated fetch (stub two pages) → per-zone candidates created with zone_id/external_id; idempotent.
- `media:sync_candidate_images[council]`: `BKK-01-03.png` → `public/images/council/01/03.png` + photo_url set on (zone 01, number 3); junk skipped; spec isolated to a tmp public dir.
- Ingest (council): real-shaped area fixture + per-zone candidate map → `ResultWriter` writes the correct per-zone candidate's votes; council snapshot has per-district winners + seats-by-party.
- Snapshot: `results-council.json` shape (seats[], per-district winner/results); governor `results.json` unchanged.
- UI: council route renders; map colors by winner; seats summary totals 50.

## Constraints
- Reuse `EctAdapter`, `Drive::FolderClient`, `VoteResult`, `ZoneStat`, `ResultRevision`, `SnapshotArchiveJob` — do not fork them.
- Governor experience unchanged (its dashboard, ingest, snapshot, tests all keep passing).
- Council photos committed under `public/images/council/<zone>/<number>.png`; served from our origin (no Drive hot-linking).
- Same event-driven archiving as governor (recurring poll → write → publish → emit `SnapshotArchiveJob`); NOT true event sourcing.

## Rollout
1. Migrate. 2. Seed the council election + zones. 3. `rake ect:sync_candidates[council]` (populate ~262 per-zone candidates). 4. `rake media:sync_candidate_images[council]` (photos) + commit. 5. Council ingest recurring begins polling; `/council` tab goes live.
