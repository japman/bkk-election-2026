# Richer Governor Zone Detail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Enrich the governor zone-detail panel from "top 3 + counted %" to the full candidate list + per-district stats + photos.

**Architecture:** Expand the `zones[]` payload in `ResultsSnapshot` (data already written by the ingest pipeline) and update `zone_detail_controller.js` to render a stats block + all candidates (reusing Sub-project A photos/logos).

**Tech Stack:** Rails 8.1, RSpec, Stimulus JS.

**Design spec:** `docs/superpowers/specs/2026-06-24-zone-detail-rich-design.md`

## Global Constraints

- Serialization/UI only — do NOT touch ingest, `ResultWriter`, `ZoneStat`, or models.
- `zones[]` keeps `leader_number` + `counted_percent` (the map reads them); replaces `top` with full `results` (all candidates, votes desc) and adds `stats: {eligible_voters, turnout, bad_ballots, no_vote}` (all nil-safe → 0).
- Candidate name/photo_url/party_logo_url are joined client-side from the existing top-level `candidates[]` map — do NOT duplicate per-candidate metadata inside each zone.
- Reuse Sub-project A CSS classes `.zd-photo` / `.party-logo` and the existing fallback (color dot / letter).
- TDD: failing test first. Run via `rtk bundle exec rspec ...`. Commit per task. Do NOT push.

---

### Task 1: Enrich `ResultsSnapshot` zones[] with stats + full results

**Files:**
- Modify: `app/services/results_snapshot.rb`
- Test: `spec/services/results_snapshot_spec.rb` (append)

**Interfaces:**
- Produces: each `zones[]` entry gains `stats: {eligible_voters:, turnout:, bad_ballots:, no_vote:}` (integers) and `results: [{number, votes}]` for ALL candidates sorted by votes desc; `top` is removed.

- [ ] **Step 1: Write the failing test** (append to `spec/services/results_snapshot_spec.rb`)

```ruby
  it "includes full per-zone results (all candidates) and zone stats" do
    e = build_election(zones: 1, candidates: 4)
    zone = e.zones.first
    e.candidates.order(:number).each_with_index do |c, i|
      VoteResult.create!(zone: zone, candidate: c, votes: (i + 1) * 100)
    end
    ZoneStat.create!(zone: zone, eligible_voters: 5000, turnout: 3000,
                     bad_ballots: 40, no_vote: 20, counted_percent: 80.0)
    z = described_class.new(e).as_json[:zones].first
    expect(z[:results].size).to eq(4)                       # all candidates, not capped at 3
    expect(z[:results].map { |r| r[:votes] }).to eq([400, 300, 200, 100]) # desc
    expect(z[:stats]).to eq(eligible_voters: 5000, turnout: 3000, bad_ballots: 40, no_vote: 20)
    expect(z).not_to have_key(:top)
  end

  it "renders zone stats as 0 when the zone has no zone_stat" do
    e = build_election(zones: 1, candidates: 1)
    z = described_class.new(e).as_json[:zones].first
    expect(z[:stats]).to eq(eligible_voters: 0, turnout: 0, bad_ballots: 0, no_vote: 0)
  end
```

- [ ] **Step 2: Run, verify fail**

Run: `rtk bundle exec rspec spec/services/results_snapshot_spec.rb`
Expected: FAIL (no `:stats`/`:results` keys; `:top` still present).

- [ ] **Step 3: Implement** — in `app/services/results_snapshot.rb`, replace the `zones:` block:

```ruby
      zones: @election.zones.order(:code).includes(:zone_stat, vote_results: :candidate).map do |z|
        top = z.vote_results.sort_by { |r| -r.votes }.first(3)
        { code: z.code, name: z.name,
          leader_number: top.first&.candidate&.number,
          counted_percent: z.zone_stat&.counted_percent.to_f,
          top: top.map { |r| { number: r.candidate.number, votes: r.votes } } }
      end
```
with:
```ruby
      zones: @election.zones.order(:code).includes(:zone_stat, vote_results: :candidate).map do |z|
        ranked = z.vote_results.sort_by { |r| -r.votes }
        st = z.zone_stat
        { code: z.code, name: z.name,
          leader_number: ranked.first&.candidate&.number,
          counted_percent: st&.counted_percent.to_f,
          stats: { eligible_voters: st&.eligible_voters.to_i, turnout: st&.turnout.to_i,
                   bad_ballots: st&.bad_ballots.to_i, no_vote: st&.no_vote.to_i },
          results: ranked.map { |r| { number: r.candidate.number, votes: r.votes } } }
      end
```

- [ ] **Step 4: Run, verify pass**

Run: `rtk bundle exec rspec spec/services/results_snapshot_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add app/services/results_snapshot.rb spec/services/results_snapshot_spec.rb
rtk git commit -m "Enrich zones snapshot with full results + per-district stats"
```

---

### Task 2: Render full candidate list + stats in the zone-detail panel

**Files:**
- Modify: `app/javascript/controllers/zone_detail_controller.js`, `app/views/dashboard/_map.html.erb`, `app/assets/stylesheets/application.css`
- Test: none automated (JS render verified by inspection; the Task 1 snapshot shape is the contract). Verify the full suite stays green.

**Interfaces:**
- Consumes: `zone.results` (all), `zone.stats`, and the top-level `data.candidates[]` map (`photo_url`/`party_logo_url`/`name`/`color`).

- [ ] **Step 1: Add a stats target to the panel** — in `app/views/dashboard/_map.html.erb`, inside the `.zone-detail` panel, add a stats element before the rows target:

```erb
  <div class="zd-stats" data-zone-detail-target="stats"></div>
```
(Place it between the `.zd-head` div and the `data-zone-detail-target="rows"` div. Add `stats` to the controller's `static targets` in the next step.)

- [ ] **Step 2: Update `zone_detail_controller.js`** — read current file, then:
  1. Add `"stats"` to `static targets = [...]`.
  2. In `render(code)`, after setting name/counted, build the stats line and iterate `zone.results` (not `zone.top`):

```javascript
  render(code) {
    // ... existing fetch + const zone + const byNumber ...
    const sum = zone.results.reduce((s, r) => s + r.votes, 0)

    this.nameTarget.textContent = `เขต${zone.name}`
    this.countedTarget.textContent = `นับแล้ว ${zone.counted_percent}%`

    const s = zone.stats || {}
    const nf = (n) => (n || 0).toLocaleString("th-TH")
    const turnoutPct = s.eligible_voters ? (s.turnout * 100 / s.eligible_voters).toFixed(1) : "0.0"
    this.statsTarget.innerHTML =
      `ผู้มีสิทธิ์ ${nf(s.eligible_voters)} • มาใช้สิทธิ์ ${nf(s.turnout)} (${turnoutPct}%) • บัตรเสีย ${nf(s.bad_ballots)} • ไม่ประสงค์ ${nf(s.no_vote)}`

    this.rowsTarget.innerHTML = zone.results.map(t => {
      const c = byNumber.get(t.number)
      const pct = sum === 0 ? 0 : (t.votes * 100 / sum).toFixed(1)
      return `<div class="zd-row">
        ${c.photo_url ? `<img class="zd-photo" src="${c.photo_url}" alt="" loading="lazy">` : `<i style="background:${c.color}"></i>`}
        <span class="zd-name">เบอร์ ${c.number} ${c.name}${c.party_logo_url ? ` <img class="party-logo" src="${c.party_logo_url}" alt="">` : ""}</span>
        <span class="zd-v num">${t.votes.toLocaleString("th-TH")} (${pct}%)</span>
      </div>`
    }).join("")
    this.panelTarget.classList.add("show")
  }
```
(Preserve the existing `fetch("/results.json", {cache:"no-store"})`, `zone` lookup, `byNumber` construction, and any early-returns. Only the stats line and the `zone.results` iteration are new; the row template is the Sub-project A version.)

- [ ] **Step 3: Add CSS** — append to `app/assets/stylesheets/application.css`:

```css
.zd-stats{ font-size:12px; color:var(--muted,#6b7280); margin:6px 0 10px; line-height:1.5; }
.zone-detail [data-zone-detail-target="rows"]{ max-height:46vh; overflow-y:auto; }
```

- [ ] **Step 4: Verify the suite + confirm JS parses**

Run: `rtk bundle exec rspec`
Expected: PASS (no regressions). Confirm `zone_detail_controller.js` has balanced backticks/braces (read it once).

- [ ] **Step 5: Commit**

```bash
rtk git add app/javascript/controllers/zone_detail_controller.js app/views/dashboard/_map.html.erb app/assets/stylesheets/application.css
rtk git commit -m "Render full candidate list + district stats in zone-detail panel"
```

---

## Self-Review

**Spec coverage:** snapshot full results + stats (Task 1) ✓; JS renders stats block + all candidates with photos (Task 2) ✓; reuse A imagery/fallback (Task 2 row template) ✓; map still uses leader_number/counted_percent (Task 1 keeps them) ✓; nil-safe stats (Task 1 `.to_i`) ✓.

**Placeholder scan:** complete code in every step; commands have expected output; no TBD.

**Type consistency:** `zones[].results` (array of `{number, votes}`) + `zones[].stats` (4 integer keys) produced in Task 1, consumed in Task 2 (`zone.results`, `zone.stats`); `byNumber` join uses `candidates[].photo_url/party_logo_url/name/color` (present since Sub-project A); `top` removed in Task 1 and no longer referenced in Task 2.
