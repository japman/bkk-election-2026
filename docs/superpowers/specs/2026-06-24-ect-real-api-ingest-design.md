# Design: Rewrite Ingest Layer for the real ECT Media API

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan
**Scope:** Replace the assumed/fictional ingest payload shape with the real ECT
(Election Commission of Thailand) media API for `bkk-governor-2026`.

## Problem

The current ingest layer (`Ingest::Client`, `Ingest::EctAdapter`) was built
against an assumed payload shape captured in `spec/fixtures/ingest/valid.json`
(`{ zones: [{ code, counted_percent, eligible, turnout, bad, no_vote,
results:[{number, votes}] }] }`). The real ECT API — verified with live demo
calls on 2026-06-24 — is completely different: bearer-authed, a different URL,
a `data.areas[]` envelope, candidate IDs as UUIDs (not ballot numbers), and
camel/snake-cased stat fields. With the current code the app would receive zero
usable data in production.

## Confirmed facts about the real API (live-verified)

- **Base:** `https://media.election.in.th`
- **Auth:** `Authorization: Bearer <token>` (scheme `bearerAuth`, `bearerFormat: API_KEY`). 403 `FORBIDDEN_ELECTION_ACCESS` if the token's scope excludes the election. Rate limit ~200 req/min (demo key lower); headers `X-RateLimit-*`; 429 carries `retryAfter`.
- **Canonical surface:** `/auto/*` (the `/realtime/*` and `/final/*` paths are deprecated → 308 redirect, sunset 2026-07-01). `/auto` auto-selects realtime vs final and reports the choice in `source`.
- **Per-area results endpoint** (gives the 50-district × 18-candidate matrix we need):
  ```
  GET /api/media/elections/bkk-governor-2026/auto?level=area
  ```
  Returns `data.areas[]` with 50 items (one per เขต). Real sample of one area:
  ```json
  {
    "election_id": "095f76e8-bed8-42e3-859a-2b47540ba8bd",
    "level": "area",
    "level_id": "10-46",
    "results": [
      { "votes": 33913, "percentage": 31.16, "candidate_id": "4ca853a4-c99e-39d9-a519-b5697be547f8" }
    ],
    "metadata": {
      "good_votes": 108851, "total_votes": 112117, "invalid_votes": 2177,
      "no_votes": 1089, "stations_reported": 208, "total_stations": 6628,
      "coverage_percentage": 84.55, "total_eligible_voters": 172765,
      "voter_turnout_percentage": 64.9, "last_updated": "2026-06-24T10:10:02.688Z"
    },
    "province_code": "10", "province_name": "กรุงเทพมหานคร", "area_number": 46
  }
  ```
  Note: `level=province` returns a single Bangkok aggregate (not per-area); `level=area` is what we use.
- **Candidates endpoint** (UUID → ballot number/name/party/color):
  ```
  GET /api/media/elections/bkk-governor-2026/auto/candidates
  ```
  `data.candidates[]` (18 items). Real sample of one:
  ```json
  { "id": "4ca853a4-c99e-39d9-a519-b5697be547f8", "number": 7,
    "name": "นายภาสพงศ์ ไชยวิริญะวาณิชย์", "provinceCode": "10",
    "totalVotes": 989613, "rank": 1, "percentage": 32.79,
    "party": { "id": "...", "code": "IND", "name": "อิสระ", "color": "#888888" } }
  ```
- **Envelope (every endpoint):** `{ success, data, correlationId, source }`. `source` = `{ selected: "realtime"|"final", finalProgress, realtimeProgress, threshold, competitiveAreasTotal, areasWithData, reason }`.

## Goals / Non-goals

**Goals:** ingest real per-area governor results + stats every poll; resolve
candidate UUIDs to our ballot numbers via a persisted `external_id`; sync the 18
real candidates from the API; keep the existing downstream (ResultWriter,
broadcaster, snapshot/archive, UI) unchanged.

**Non-goals:** changing the 50-zone model or UI; per-station data; storing the
`source` object in the DB (log only); rate-limit backpressure beyond existing
retry (single result call + occasional candidate sync stays well under limits).

## Architecture & data flow

```
rake ect:sync_candidates            (run before counting; re-runnable)
  └─ Ingest::Client.fetch_candidates → GET /auto/candidates
     └─ upsert Election.current.candidates by number:
        name, party (=party.name), color (=party.color), external_id (=id UUID)

IngestPollJob  (every 30s — control flow unchanged)
  ├─ candidate_map = election.candidates.where.not(external_id: nil)
  │                          .pluck(:external_id, :number).to_h        # UUID → number
  ├─ raw = Ingest::Client.fetch_results                                # GET /auto?level=area
  ├─ parsed = Ingest::EctAdapter.parse(raw,
  │              expected_zone_codes: election.zones.pluck(:code),
  │              candidate_map: candidate_map)
  │     └─ data.areas[] → { "01".."50" => { votes: {number=>votes}, stats: {...} } }
  ├─ per zone: ResultWriter.new(zone, source:"api").apply!(votes, stats:)   # unchanged
  ├─ ResultsBroadcaster (if changed)                                        # unchanged
  ├─ SnapshotPublisher#publish                                              # unchanged
  └─ SnapshotArchiveJob.perform_later(...)                                  # unchanged
```

## Components

### 1. Migration — `add_external_id_to_candidates`
Add `external_id :string` to `candidates`, nullable, with a **partial unique
index**: `add_index :candidates, :external_id, unique: true, where: "external_id IS NOT NULL"`.
Stores the ECT candidate UUID. Nulls allowed (candidates not yet synced).

### 2. `Ingest::Client` (rewrite)
- All requests send `Authorization: Bearer #{ENV.fetch("ECT_API_TOKEN")}`.
- `base = ENV.fetch("ECT_API_URL")` = `https://media.election.in.th/api/media/elections/bkk-governor-2026`.
- `self.fetch_results` → GET `#{base}/auto?level=area`, returns the parsed JSON `Hash` (raise `FetchError` on non-2xx, timeout, socket/SSL errors, or invalid JSON).
- `self.fetch_candidates` → GET `#{base}/auto/candidates`, returns parsed JSON `Hash`.
- Shared private helper builds the request, sets the bearer header, applies the existing 5s/10s open/read timeouts, and maps transport errors + non-success HTTP (incl. 401/403/429) to `FetchError` with a descriptive message. Keep `FetchError` so `IngestPollJob`'s existing `retry_on` still applies.

### 3. `Ingest::EctAdapter` (rewrite `parse`)
- New signature: `parse(raw, expected_zone_codes:, candidate_map:)` where `raw`
  is the parsed results JSON and `candidate_map` is `{ uuid_string => number }`.
- Read `raw.dig("data", "areas")`. For each area:
  - `code = format("%02d", area["area_number"])` — validate it's in `expected_zone_codes`.
  - For each `result` in `area["results"]`: translate `result["candidate_id"]`
    via `candidate_map` → number; collect `{ number => result["votes"] }`.
  - Map `area["metadata"]` → stats hash:
    `eligible_voters = total_eligible_voters`, `turnout = total_votes`,
    `bad_ballots = invalid_votes`, `no_vote = no_votes`,
    `counted_percent = coverage_percentage`.
- **Validation (all-or-nothing, matches current philosophy):** reject the whole
  payload (return `Result` with `errors`, write nothing) if: `success` is not
  true; areas missing/extra/duplicate vs `expected_zone_codes`; any
  `candidate_id` not in `candidate_map`; votes/stat not a non-negative integer;
  `counted_percent` outside 0–100. Errors are logged by the job as today.
- Output normalized hash identical in shape to what `ResultWriter` consumes
  today: `{ code => { votes: {number=>int}, stats: {eligible_voters:, turnout:,
  bad_ballots:, no_vote:, counted_percent:} } }`, so `ResultWriter` is untouched.

### 4. `IngestPollJob` (small change)
Build `candidate_map` from the DB, call `Client.fetch_results`, pass the map to
`EctAdapter.parse`. Everything after (zones loop, broadcaster, publisher,
archive event) is unchanged. Log `source.selected` and coverage for visibility.
Keep the existing `ECT_API_URL.blank?` guard; also skip with a logged message
if `candidate_map` is empty (sync not yet run) to avoid rejecting every poll.

### 5. `rake ect:sync_candidates` (new, `lib/tasks/ect.rake`)
For `Election.current`: call `Client.fetch_candidates`, upsert each
`data.candidates[]` into `election.candidates` keyed by `number` with `name`,
`party = party.name`, `color = party.color`, `external_id = id`. Idempotent.
Logs counts. Intended to run once (or when the candidate list changes) before
polling produces writeable data.

### 6. Config / secrets
- New secret `ECT_API_TOKEN` → credentials `kamal.ect_api_token`, referenced in
  `.kamal/secrets`, listed in `deploy.yml` `env.secret`.
- `ECT_API_URL` value becomes the election base URL above. It is already wired
  through `.kamal/secrets` and `deploy.yml` `env.secret`; in production its value
  comes from credentials `kamal.ect_api_url` (currently a placeholder — set to
  `https://media.election.in.th/api/media/elections/bkk-governor-2026`).

## Not touched
`ResultWriter`, `ResultsBroadcaster`, `SnapshotPublisher`, `SnapshotArchiveJob`,
`ZoneStat`/`VoteResult`/`Zone` models, `ResultsSnapshot`, the UI.

## Error handling
- Transport / auth / rate-limit / bad-JSON → `FetchError` → existing job
  `retry_on` (2 attempts, 5s) then the recurring 30s tick.
- Payload validation failure → reject whole payload, log errors, write nothing
  (no partial/zeroed state), as today.
- Unknown `candidate_id` → treated as a validation failure (signals the sync
  task must be run / candidate list drifted).

## Testing (RSpec)
Use the live-captured responses as fixtures (saved during design at
`/tmp/gov-area.json`, `/tmp/gov-cands.json`).
- **Client:** stub HTTP; assert bearer header present and correct URLs for
  `fetch_results` / `fetch_candidates`; `FetchError` on 401/403/429/timeout/
  malformed JSON.
- **Adapter:** real-shaped area fixture + a candidate_map → exact normalized
  output (codes `01..50`, number-keyed votes, mapped stats); reject cases:
  missing/extra area, unknown candidate_id, negative vote, out-of-range
  counted_percent, `success:false`.
- **Sync task:** stub `fetch_candidates` → 18 candidates upserted with
  `external_id`, party/color from `party.*`; re-run is idempotent.
- **IngestPollJob:** builds the map, calls the new client/adapter, writes
  results+stats, publishes snapshot, enqueues `SnapshotArchiveJob`; empty-map
  guard path. Update existing fixtures/stubs accordingly.

## Rollout
1. Deploy code. 2. Set `ECT_API_TOKEN` (real partner token) in credentials.
3. Run `rake ect:sync_candidates` once (populates 18 candidates + external_id).
4. Polling then writes real per-area data each cycle.
