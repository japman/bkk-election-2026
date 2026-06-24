# Design: Richer governor zone detail (Sub-project C)

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan
**Scope:** Enrich the governor dashboard's zone-detail panel from "top 3 + counted %" to the full candidate list, full per-district statistics, and candidate photos. UI/serialization only — the underlying data is already written by the ingest pipeline. Independent of Sub-project B (council).

## Problem

Clicking a เขต on the governor map opens a panel that shows only the top 3 candidates (number, name, votes, %) and the counted percentage. Users want the full per-district picture: every candidate ranked, the district's voting statistics (eligible voters, turnout, spoiled/no-vote ballots), and the candidate photos already imported in Sub-project A.

## Current state (what exists)

- `ResultsSnapshot#as_json` `zones[]` entries are: `{ code, name, leader_number, counted_percent, top: [{number, votes} × up to 3] }` (`app/services/results_snapshot.rb`).
- `zone_detail_controller.js` fetches `/results.json`, finds the zone, maps `data.candidates` by number, and renders the `top` rows (color dot / photo + name + votes + %).
- The data already exists: `ResultWriter` writes a `VoteResult` for **every** candidate in every zone, and `ZoneStat` holds `eligible_voters`, `turnout`, `bad_ballots`, `no_vote`, `counted_percent` per zone.
- `data.candidates[]` already carries `photo_url` / `party_logo_url` (Sub-project A).

## Goals / Non-goals

**Goals:** zone detail shows (1) all candidates for the district ranked by votes, with photo + party logo + votes + in-district %, and (2) a stats block (eligible voters, turnout + %, spoiled ballots, no-vote). Reuse Sub-project A imagery and the existing fallback.

**Non-goals:** council/สก (Sub-project B); changing the map or leaderboard; new endpoints; pagination/virtualization (≤18 rows is fine).

## Design

### 1. `ResultsSnapshot` — enrich `zones[]`
Replace each zone's `top:` with the full ranked list and add a `stats` block:
```ruby
{ code:, name:, leader_number:, counted_percent:,
  stats: { eligible_voters:, turnout:, bad_ballots:, no_vote: },   # from zone.zone_stat
  results: z.vote_results.sort_by { |r| -r.votes }
            .map { |r| { number: r.candidate.number, votes: r.votes } } }  # ALL candidates, desc
```
- `stats` values come from `z.zone_stat` (nil-safe → 0 when absent).
- `results` is every candidate (was capped at 3). The existing `leader_number`/`counted_percent` stay for the map.
- Keep payload lean: `results` is number+votes only; the JS joins names/photos from the top-level `candidates[]` map (already loaded), so we don't duplicate per-candidate metadata per zone.

### 2. `zone_detail_controller.js` — render full panel
- Header: zone name + counted %.
- New **stats row**: `ผู้มีสิทธิ์ X • มาใช้สิทธิ์ Y (Z%) • บัตรเสีย B • ไม่ประสงค์ N` (Thai-formatted numbers).
- Candidate rows: iterate `zone.results` (all), join `byNumber` for name/color/photo_url/party_logo_url; render photo (fallback color dot) + number + name + party logo + votes + in-district %.
- In-district % = candidate votes / sum(results votes) (existing behavior, now over all candidates).

### 3. View/markup + CSS
- The panel container (`app/views/dashboard/_map.html.erb`) gains a stats target element; `application.css` gets a compact `.zd-stats` style and the panel becomes scrollable for ≤18 rows (`max-height` + overflow). Reuse `.zd-photo` / `.party-logo` from Sub-project A.

## Error handling
- Missing `zone_stat` → stats render as 0 (nil-safe in snapshot).
- Missing photo/logo → existing fallback (color dot / no logo).
- A zone with no results → panel shows stats + an empty list (no crash).

## Testing (RSpec)
- `ResultsSnapshot`: a zone with N candidates + a `zone_stat` → `zones[]` entry has `stats` with the four fields and `results` with all N candidates sorted desc (not capped at 3). A zone without `zone_stat` → stats all 0.
- (JS render verified by inspection; the snapshot shape is the testable contract.)

## Constraints
- Serialization/UI only; do NOT touch ingest, `ResultWriter`, `ZoneStat`, models.
- Reuse Sub-project A `photo_url`/`party_logo_url` already in `candidates[]`.
- Backward-compatible: the map still reads `leader_number`/`counted_percent`; only the panel consumes `stats`/`results`.
