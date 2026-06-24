# Design: Candidate photos & party logos (Sub-project A)

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan
**Scope:** Governor (bkk-governor-2026) candidate photos + party logos — import from a public Google Drive folder, store in the repo, display in the leaderboard and zone-detail panel with graceful fallback. First of three sub-projects (A=images, C=richer zone detail, B=สก council).

## Problem

The app shows 18 governor candidates by a colored letter-avatar (first letter of name) and a party name string. `candidates.photo_url` exists but is unused; there is no party-logo field, no ActiveStorage. We have a public Drive folder with real candidate photos and party logos, and the ECT API supplies candidate `number`/`party`. We want real photos + party logos rendered, served from our own origin (no hot-linking).

## Verified data source (live-checked 2026-06-24)

Public Drive root folder `1woPf0tDxEPe__TUnUP0eJPvo9QBZbbrW` contains three subfolders:

| Subfolder | Folder ID | Contents | Mapping |
|---|---|---|---|
| ภาพ ผ.ถ. (governor) | `1wFbkHhM2YotcEmY045yLVN9JteMlFvpJ` | `BKK-001.png` … `BKK-018.png` | `BKK-0NN` → candidate **number N** |
| โลโก้ (party logos) | `1Z01qgR20v2maDupmwWrgsECJN5UbOIgD` | `ประชาชน.png`, `ประชาธิปัตย์.png`, `เพื่อไทย Life ลงตัว.png`, `เศรษฐกิจ.png`, `อนาคตไทย.png`, `BETTER BANGKOK.png`, `กรุงเทพบินได้.jpg`, `คนทำงาน1.jpg`, `คนทำงาน2.jpg`, `มีนบุรี พึ่งได้.png` (+ junk `.DS_Store`, `Thumbs.db`) | filename stem ≈ **party name** |
| ภาพ ส.ก. (council) | `1KFXxX44NpaRTNH8pY6EtKxqw6bSPeJXY` | per-district สก photos | **out of scope** here (reused in Sub-project B) |

**Mechanics that work without an API key (verified):**
- List a public folder: `GET https://drive.google.com/embeddedfolderview?id=<folderId>#list` → server-rendered HTML; each entry has `id="entry-<fileId>"` and `flip-entry-title">"<filename>"`.
- Download a file: `GET https://drive.google.com/uc?export=download&id=<fileId>` → raw bytes (verified: BKK-007 → PNG 324×523, 314 KB).

## Goals / Non-goals

**Goals:** import governor photos + party logos into `public/images/`, persist their URLs on candidates, expose them in `results.json`, and render them (leaderboard + zone detail) with graceful fallback to the existing letter-avatar.

**Non-goals:** สก photos (Sub-project B); ActiveStorage; live/continuous image refresh (a manual rake task is enough — candidate imagery is static during an election); editing/cropping UI.

## Architecture & data flow

```
rake media:sync_candidate_images   (run manually; idempotent; committed output)
  ├─ Drive::FolderClient.list(GOV_FOLDER_ID)  → [{id, name}]  (embeddedfolderview)
  │    for each BKK-0NN.<ext>: download → optimize(webp, ~320px) → public/images/candidates/NN.webp
  │    set Election.current.candidates[number=N].photo_url = "/images/candidates/NN.webp"
  └─ Drive::FolderClient.list(LOGO_FOLDER_ID) → [{id, name}] (skip .DS_Store / Thumbs.db / non-image)
       for each logo: download → optimize → public/images/parties/<slug>.webp
       for each candidate: match candidate.party to a logo (normalized) → set party_logo_url
       log candidates whose party matched no logo (e.g. "อิสระ" independents — no logo, expected)

results.json (ResultsSnapshot) candidates[] gains: photo_url, party_logo_url (may be null)
        │
   Browser:
   - leaderboard partial: <img src=photo_url> with onerror → letter-avatar; party logo beside party name
   - zone_detail_controller.js: small photo + party logo per row, fallback when absent
```

## Components

### 1. `Drive::FolderClient` (new service) — `app/services/drive/folder_client.rb`
- `list(folder_id) -> Array<{id:, name:}>`: GET `embeddedfolderview?id=<folder_id>`, parse `entry-<id>` + `flip-entry-title` pairs. Raises `Drive::FolderClient::Error` on non-2xx.
- `download(file_id) -> String (bytes)`: GET `uc?export=download&id=<file_id>`; raises on non-2xx.
- Net::HTTP, 10s/30s timeouts, `Mozilla/5.0` UA. No auth/key needed (public folder).

### 2. Migration — `add_party_logo_url_to_candidates`
Add `party_logo_url :string` (nullable) to `candidates`. (`photo_url` already exists.)

### 3. `rake media:sync_candidate_images` — `lib/tasks/media.rake`
- Folder IDs from constants/ENV (default to the verified governor + logo IDs; ENV overridable so สก can reuse in B).
- Governor: filter names matching `/\ABKK-(\d{3})\./i` → number = captured int; download → `optimize` → write `public/images/candidates/<number>.webp`; set `candidate.photo_url`.
- Logos: skip names matching `/\A\./` or `Thumbs.db` or non-image extensions; download → write `public/images/parties/<slug>.webp` (slug = normalized filename stem); build `{normalized_party_name => "/images/parties/<slug>.webp"}`.
- Party match: normalize both sides (strip spaces, NFC, downcase ASCII) and match candidate.party to a logo key; set `party_logo_url` or leave nil (log misses).
- Idempotent (overwrite files; re-set URLs). Logs counts (photos written, logos written, candidates matched/unmatched).

### 4. Image optimization
Use `image_processing` (ruby-vips; libvips is already in the Docker base image) to resize to max width 320px and convert to `.webp`. If libvips is unavailable locally, fall back to writing the original bytes with the original extension and set the URL accordingly (the task logs which path it took). Keep the helper isolated so the fallback is a one-line branch.

### 5. `ResultsSnapshot` — `app/services/results_snapshot.rb`
Add `photo_url: c.photo_url, party_logo_url: c.party_logo_url` to each `candidates[]` entry (alongside number/name/party/color/votes/percent). Values may be null.

### 6. Display
- **`app/views/dashboard/_leaderboard.html.erb`**: replace the `.avatar` letter with an `<img class="avatar-img" src="<photo_url>" alt loading="lazy" onerror="this hide → show .avatar letter">`; when `photo_url` is blank, render the letter-avatar directly (no broken-image flash). Add a small party logo `<img>` next to the party text when `party_logo_url` present.
- **`app/javascript/controllers/zone_detail_controller.js`**: in each `zd-row`, prepend a small candidate photo (from the `byNumber` candidate, using `photo_url`) with a color-dot fallback, and the party logo when present.
- CSS: `.avatar-img` (same 52px circle, `object-fit: cover`), small `.party-logo` (≈18px) and `.zd-photo` (≈28px). Reuse existing `--c` color for fallbacks.

### 7. Tests (RSpec)
- **Drive::FolderClient**: webmock-stub `embeddedfolderview` (a small fixture HTML with 2 entries) → returns `[{id,name}]`; stub `uc?export=download` → returns bytes; non-2xx → `Error`.
- **media:sync_candidate_images**: stub `Drive::FolderClient.list`/`download`; seed candidates (numbers + parties); run task → asserts files written to `public/images/...` (use a tmp dir or assert `File.exist?` then clean up), `photo_url` set for matched numbers, `party_logo_url` set for matched parties, junk filenames skipped, unmatched parties left nil. Use a real tiny PNG fixture for download bytes.
- **ResultsSnapshot**: candidates[] include `photo_url`/`party_logo_url`.
- **Leaderboard render** (view or request spec): renders `<img>` when photo_url present; renders letter-avatar when absent.

## Error handling
- Drive list/download failure → task logs the error per file and continues with the rest (one bad file must not abort the import); summary reports failures. The `Drive::FolderClient` itself raises; the task rescues per-item.
- Missing photo/logo at render → graceful fallback (letter-avatar / no logo). Never a broken-image icon.
- `party_logo_url`/`photo_url` are nullable everywhere; nothing assumes presence.

## Constraints
- Served from our own origin (`public/images/...` via the app/kamal-proxy/CDN) — no Drive hot-linking at runtime.
- Committed images are the deploy artifact (the sync task is a build/prep step, not a runtime dependency).
- Reuse-ready: folder IDs configurable so Sub-project B can import ภาพ ส.ก. with the same `Drive::FolderClient` + task pattern.

## Rollout
1. Run `rake media:sync_candidate_images` locally → downloads into `public/images/` and sets `photo_url`/`party_logo_url` on the dev DB candidates. (Done: 18 photos + 10 party logos committed; 3 party candidates matched, the rest are independents with no logo.)
2. Commit the generated `public/images/...` files (the deploy artifact — they ship in the Docker image and are served by the app/kamal-proxy).
3. Deploy.
4. Run `rake media:sync_candidate_images` once in production to populate the URL columns on the production DB candidates. NOTE: the current task re-downloads from Drive each run, so the production run requires outbound access to `drive.google.com` / `drive.usercontent.google.com` at run time. (The Kamal container filesystem is ephemeral, but the images ship committed in the image, so only the URL columns need populating — re-running after each deploy is not required for the files, only after a fresh DB.) A future optimization could set URLs from the already-shipped files without re-downloading.

**Live-verified mechanics:** `uc?export=download` returns a 303 to `drive.usercontent.google.com` (the client follows redirects); folder filenames are UTF-8 (Thai), so the listing is re-tagged UTF-8; per-item failures are logged and skipped so one bad file never aborts the import.

**Decision (no convention fallback):** `photo_url`/`party_logo_url` are the single source of truth, set by the task and read directly by `ResultsSnapshot`. When a value is nil (e.g. candidate not yet synced, or independent party with no logo), the UI falls back to the letter-avatar / no-logo. `ResultsSnapshot` does NOT derive paths by convention — nil simply means "no image", keeping fallback behavior uniform and explicit.
