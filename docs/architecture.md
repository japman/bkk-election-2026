# สถาปัตยกรรมระบบ — รายงานผลเลือกตั้ง กทม. 2569

ระบบรายงานผลเลือกตั้ง **ผู้ว่าฯ กทม.** และ **สมาชิกสภากรุงเทพฯ (สก.)** แบบเรียลไทม์
วันเลือกตั้ง **28 มิ.ย. 2569** — โดเมน `bkk-election-2026.dailynews.co.th`

หลักการออกแบบ: **edge-first** — ผู้ชมส่วนใหญ่อ่านข้อมูลจาก CDN/edge cache ไม่ใช่จาก origin โดยตรง
ทำให้รับโหลด concurrent สูงได้โดย origin ทำงานเกือบคงที่ (O(1)) แม้คนดูจะหลักหมื่น

> **สถานะปัจจุบัน (28 มิ.ย. 2026 — วันเลือกตั้ง, อัปเดตล่าสุด):** prod รันบน **เครื่อง 8 vCPU / 16 GB** (`159.138.255.93`) หลัง cutover แบบ blue-green จากเครื่องเดิม 2vCPU/3.4GB; tune ครบ (FD 65536, Puma 5 workers, PG/Redis tuned, somaxconn 65535); Cloudflare Cache Rule cache `/`+`/council` (edge TTL 60s); หน้า public มี countdown splash + cookie consent (Consentrix) + Google Analytics + SEO/OG. ดู §8, §9, §12.

---

## 1. Tech Stack

| ชั้น | เทคโนโลยี |
|------|-----------|
| Framework | Rails 8.1 (monolith), ERB views |
| Frontend | Hotwire — Turbo Streams / Turbo Frames + Stimulus (importmap, Propshaft) |
| Realtime | Action Cable over Redis adapter (`/cable`) |
| Background jobs | Solid Queue (รันใน Puma, `SOLID_QUEUE_IN_PUMA=1`) |
| Cache/Cable store | Redis 7 |
| Database | PostgreSQL 17 (ใช้ jsonb สำหรับ trend points) |
| Edge | Cloudflare (HTML micro-cache + SSL Full-strict) + CloudFront (snapshot JSON) |
| Object store | AWS S3 (`results.json` / `results-council.json`) |
| Analytics / Consent | Google Analytics (gtag.js) + Consentrix cookie consent (CMP) — ใน layout `<head>` |
| Deploy | Kamal 2 → Huawei Cloud single host (`159.138.255.93`, **8 vCPU / 16 GB**) |

---

## 2. ภาพรวมสถาปัตยกรรม (Edge-first)

```
                    ┌──────────────────────── ผู้ชม (browser) ───────────────────────┐
                    │                                                                 │
         (1) HTML   │                                  (2) ข้อมูลสด                    │
                    ▼                                                                 ▼
            ┌───────────────┐                                          ┌──────────────────────┐
            │  Cloudflare   │  HTML micro-cache (Cache Rules)          │   เส้นทางข้อมูลสด 2 ทาง │
            │  (SSL term.)  │  + WS passthrough (/cable → 101)         └──────────┬───────────┘
            └───────┬───────┘                                                     │
                    │ miss / dynamic                       ┌──────────────────────┴───────────────────────┐
                    ▼                                      ▼ (A) Live: WebSocket           ▼ (B) Fallback: poll
            ┌───────────────┐                      ┌────────────────┐              ┌──────────────────────┐
            │   Rails app   │  Turbo Stream  ──────▶│  Action Cable  │              │  CloudFront (TTL 5s) │
            │  (Puma+Solid  │  broadcast            │  (Redis)/cable │              │   → S3 results.json  │
            │   Queue)      │                       └────────────────┘              └──────────┬───────────┘
            └───────┬───────┘                                                                  │ publish
                    │                                                                          │
                    ├─────────────── SnapshotPublisher.publish ────────────────────────────────┘
                    │
              ┌─────▼──────┐         ทุก 30 วิ          ┌──────────────────┐
              │ PostgreSQL │◀──── IngestPollJob ───────│  ECT Partner API  │
              └────────────┘   (Solid Queue recurring) └──────────────────┘
```

**สองเส้นทางส่งข้อมูลสดถึง client (วิ่งคู่กัน, recover เองอัตโนมัติ):**
- **(A) Live push** — Turbo Stream broadcast ผ่าน WebSocket → อัปเดตทันทีเมื่อมีคะแนนเปลี่ยน (latency ต่ำสุด)
- **(B) Safety-net poll** — Stimulus `fallback_controller` poll `results.json` ผ่าน CloudFront ทุก 10 วิ ถ้าไม่มี stream เข้ามาเกิน `staleAfter` (default 15 วิ) — โหลดตกที่ CDN ไม่ใช่ origin

---

## 3. Data Flow (ingest → store → publish → client)

```
IngestPollJob (recurring ทุก 30 วิ, แยก governor / council)
  │
  ├─ Ingest::Client.fetch_results(slug)         ── ดึง raw จาก ECT API
  ├─ Ingest::EctAdapter.parse(...)              ── validate + map external_id → number
  │     └─ ถ้า parsed ไม่ ok → log + return (กันข้อมูลพังเขียนทับของดี)
  ├─ ResultWriter#apply!(votes, stats)          ── เขียนต่อ zone (กัน StaleVotesError)
  │     └─ คืน changed = true/false
  │
  ├─ ถ้า changed && governor:
  │     ├─ election.record_trend_point!         ── เก็บ trend จุดใหม่ (jsonb, เก็บ 300 จุดล่าสุด)
  │     └─ ResultsBroadcaster#broadcast_all      ── Turbo Stream replace 4 region  ◀── เส้นทาง (A)
  │           (begin/rescue: broadcast ล้มไม่ทำให้ vote write ล้ม)
  │
  ├─ SnapshotPublisher#publish                   ── เขียน results.json → S3 (max-age=5)  ◀── เส้นทาง (B)
  └─ SnapshotArchiveJob.perform_later(...)       ── archive snapshot ไว้ย้อนหลัง
```

**`ResultsSnapshot`** = payload เดียวที่ใช้ร่วมกันทั้ง 3 จุด: polling fallback, กราฟ trend, และ zone detail
- governor JSON: `candidates[]`, `zones[]`, `stats`, `trend[]` (60 จุดล่าสุด)
- council JSON: `districts[]` (พร้อม winner), `seats` (`council_seat_breakdown` — รวมที่นั่งตามพรรค)

**`ResultsBroadcaster`** push 4 region ของหน้า governor ผ่าน stream `"results"`:
`header-status`, `leaderboard`, `zone-map`, `overview-stats` (target id ต้องตรงกับ root element ของ partial)

---

## 4. ชั้น Caching (ทำไมรับโหลดเยอะได้)

| สิ่งที่ cache | ที่ไหน | TTL | ใครจัดการ |
|---------------|--------|-----|-----------|
| HTML หน้า `/`, `/council` | Cloudflare (Cache Rule) micro-cache | สั้น (วินาที) | Cloudflare dashboard (user) |
| HTML response header | Rails `expires_in 5.seconds, public, stale-while-revalidate: 30` | 5s + SWR 30s | app |
| Snapshot JSON (`results*.json`) | CloudFront → S3 | 5 วิ (`cache_control: max-age=5`) | app เขียน, CDN cache |
| `/admin` | bypass / DYNAMIC | — | Cloudflare (user) |

**ผลลัพธ์:** ผู้ชม N คน → origin เห็นแค่ ~1 hit ต่อ TTL window (ที่เหลือ edge ตอบ)
ทั้ง HTML และ data path ถูก cache → origin ทำงานเกือบคงที่ ไม่ผูกกับจำนวนคนดู

---

## 5. Kill-switch ลด WebSocket (โหมด peak)

ควบคุมด้วยคอลัมน์ `elections.live_streaming` (boolean, default `true`) — flip สดผ่าน **Admin > Live WebSocket**

```
live_streaming = true (ปกติ):
  หน้าเว็บ subscribe turbo_stream_from "results"  → ได้ push สด (เส้น A)
  fallback_controller staleAfter = 15000          → poll เฉพาะตอน stream เงียบ

live_streaming = false (peak / origin ตึง):
  หน้าเว็บ ไม่ subscribe WS เลย                    → ภาระ Action Cable = 0
  fallback_controller staleAfter = 0               → poll CDN ทันทีตั้งแต่ connect
  → ทุกคนอ่านจาก CloudFront อย่างเดียว origin O(1)
```

- visitor ที่โหลดหน้า **ใหม่** หลังปิด → poll CDN ทันที (มี `maybePoll()` ใน `connect()` ไม่รอ ~10 วิ)
- WebSocket ที่ต่อค้างอยู่เดิม → ทยอยหลุดภายใน ~5 วิ (ตาม edge-cache TTL ของ HTML)

---

## 6. หน้าเว็บ (Pages)

| Path | Controller | คำอธิบาย |
|------|-----------|----------|
| `/` | `dashboard#show` | หน้าผู้ว่าฯ — leaderboard, แผนที่ 50 เขต, กราฟ trend, stats, ข่าว (lazy frame) |
| `/council` | `council#show` | หน้า สก. — แผนที่ผู้ชนะรายเขต + panel ที่นั่งตามพรรค (poll 15 วิ) |
| `/news` | `dashboard#news` | Turbo Frame (`layout: false`) โหลดข่าวแยก — ไม่บล็อกการ render หน้าหลัก |
| `/admin` | `admin/*` | แก้คะแนน (`zone_results`), toggle mode/streaming, revisions — หลัง auth |

**ข่าว (News):** `News::Fetcher.latest` ดึง WordPress RSS category `election-bangkok-69`
- สร้าง excerpt จาก `strip_tags` + truncate(140); ดึง og:image แบบ parallel threads (อ่าน 40KB แรก)
- โหลดผ่าน Turbo Frame `loading: "lazy"` → ถ้าแหล่งข่าวล่ม หน้าหลักยังขึ้นปกติ (isolated)
- ลิงก์ข่าว `target="_blank" data-turbo="false"` → เปิดแท็บใหม่ (Frame ไม่ดักคลิก)
- og:image URL force `UTF-8` + scrub (`f.read` คืน ASCII-8BIT → ถ้า URL มี byte ไทยจะ raise `Encoding::CompatibilityError` ใน ERB → /news 500)

**Public-page chrome (layout `<head>` + `_site_header` + `show`):**
- **Countdown splash** — overlay เต็มจอบังหน้าผลจนถึง 08:00 28 มิ.ย. (auto-close ตามเวลา / คลิก 10 ครั้งเพื่อ preview) — logic ฝั่ง client ล้วน (cache-safe) + inline anti-flash script + `countdown_controller`
- **Cookie consent** Consentrix CMP (sync script โหลดก่อน GA) + **Google Analytics** gtag (`G-VVDDLK9W0E`)
- **SEO/OG/Twitter meta** ใน layout (title/description/og:image=`public/og-cover.jpg` ผ่าน `PUBLIC_ORIGIN`/canonical) + logo ภาพ `logo-dn-pink-04.webp`

---

## 7. Client-side (Stimulus controllers)

| Controller | หน้าที่ |
|-----------|--------|
| `fallback_controller.js` | safety-net poll snapshot JSON ผ่าน CDN; patch ตัวเลข/แผนที่; เวลาเป็น Asia/Bangkok |
| `council_controller.js` | poll ทุก 15 วิ repaint tiles / seats / header (หน้า สก.) |
| `trend_chart_controller.js` | วาดกราฟจาก `data.trend` (series ฝั่ง server, ไม่สะสมฝั่ง client) |
| `zone-detail` / `theme` | รายละเอียดรายเขต + สลับ dark/light |
| `countdown_controller.js` | splash นับถอยหลัง — tick, auto-close ตามเวลา, ปิดด้วย 10 คลิก (localStorage), respect reduced-motion |

เวลาแสดงผลทุกจุดบังคับ `timeZone: "Asia/Bangkok", hour12: false` + `config.time_zone = "Bangkok"` ฝั่ง server

---

## 8. Infrastructure / Deploy

```
Kamal 2  →  Huawei Cloud single host (159.138.255.93, 8 vCPU / 16 GB)
            ├─ kamal-proxy (TLS termination via Cloudflare Origin Cert, forward_headers)
            ├─ web: ghcr.io/japman/bkk-election-2026 (Thruster → Puma 5 workers × 5 threads + Solid Queue in master)
            ├─ accessory db:    postgres:17  (cmd: -c shared_buffers=2GB -c effective_cache_size=6GB ...)
            └─ accessory redis: redis:7       (cmd: --appendonly no --maxmemory 1gb ; cable pub/sub only)

Cloudflare (Full-strict, Origin Cert)  →  edge cache (Cache Rule / + /council, 60s) + WS passthrough
AWS S3 (ap-southeast-1) + CloudFront    →  snapshot JSON distribution
```

- DB/Redis อยู่ host เดียวกัน เชื่อมผ่าน network `kamal` ด้วยชื่อ container — ไม่ publish port ออกนอก
- build เป็น `amd64` (gotcha: ต้อง pre-create buildx builder `network=host` ก่อน push ghcr บน Mac)
- **Kamal build จาก git clone** → ไฟล์ asset ต้อง `git add` ก่อน reference (`image_tag`) ไม่งั้น prod 500 `Propshaft::MissingAssetError`
- **Performance tuning (28 มิ.ย.):** FD limit `ulimit -n 65536` ใน `bin/docker-entrypoint` (1 WS = 1 FD; default 1024 ตันที่ ~1000 conn) · Puma clustered `WEB_CONCURRENCY=5` · PG/Redis tuned ผ่าน accessory `cmd` (`kamal accessory reboot db|redis` เพื่อ apply — `kamal deploy` ไม่แตะ accessory) · host `net.core.somaxconn=65535` — ทั้งหมด reboot-proof
- **Blue-green cutover (28 มิ.ย.):** เครื่องใหม่เป็น disk clone ของเครื่องเดิม → deploy + reboot test บนเครื่องใหม่ → สลับ Cloudflare DNS A record → verify ผ่าน CF → ปิดเครื่องเดิม (zero downtime). เครื่องเดิม `159.138.241.201` ปิดถาวรแล้ว

---

## 9. Capacity / Scaling (election-night)

ดูรายละเอียดที่ [`docs/runbooks/election-night.md`](runbooks/election-night.md) · เป้า load test: 6000 concurrent WS + 800 req/s poll (`loadtest/ws.js`, `poll.js`)

- **ปัจจุบันรันบน 8 vCPU / 16 GB** — `WEB_CONCURRENCY=5` × `RAILS_MAX_THREADS=5`, FD 65536/worker, somaxconn 65535
- คอขวด WS ที่แท้จริงคือ **FD limit** (ก่อนแก้ default 1024 ตันที่ ~1000 conn) + RAM (~50KB/conn) — ไม่ใช่ CPU (WS idle กิน CPU น้อย, ActionCable ใช้ async reactor ไม่ผูก 1 thread/conn)
- ถ้า origin/RAM ตึง → Admin ปิด WS (kill-switch) → ทุกคน poll CDN → origin O(1) (เพดานจริงของระบบ)
- **⚠️ Load-test gotcha (Huawei anti-DDoS):** ยิง WS เยอะจาก **IP เดียว** ตันที่ ~2000 conn เพราะ Huawei Cloud anti-DDoS throttle flood per-source-IP ก่อนถึง box (box idle ตลอด) — ไม่ใช่ box รับไม่ไหว, ผู้ใช้จริงหลาย IP ไม่ชน. ต้องใช้ distributed load (หลาย source IP) ถึงจะวัด capacity จริงได้
- **⚠️ หลัง cutover** traffic มาจาก Cloudflare IPs → ควร whitelist CF ranges ใน Huawei security group กัน anti-DDoS throttle CF→origin ตอนพีค (lock origin ให้รับเฉพาะ CF IP = security ด้วย)

---

## 10. Resilience / Failure modes

| สถานการณ์ | ผลและการรับมือ |
|-----------|----------------|
| ECT API ล่ม / payload พัง | `EctAdapter.parse` reject → log + return, ไม่เขียนทับข้อมูลดี (retry 2 ครั้ง) |
| Broadcast (WS) ล้ม | begin/rescue ครอบ → vote write สำเร็จอยู่ดี; client มี poll fallback |
| คะแนนย้อนหลัง (stale) | `ResultWriter::StaleVotesError` → ข้าม zone นั้น log ไว้ |
| WebSocket หลุด | `fallback_controller` poll snapshot อัตโนมัติ; Turbo reconnect เองเบื้องหลัง |
| Origin ตึง | kill-switch ปิด WS → edge-only |
| แหล่งข่าวล่ม | ข่าวอยู่ใน lazy Turbo Frame แยก → หน้าหลักไม่ได้รับผลกระทบ |
| ผู้ชม spike | edge cache (Cloudflare HTML + CloudFront JSON) ดูดซับ origin เห็น ~1 hit/TTL |

---

## 11. แผนผังไฟล์สำคัญ

```
app/
  controllers/
    dashboard_controller.rb        # show (governor), news (frame)
    council_controller.rb          # หน้า สก.
    admin/elections_controller.rb  # toggle_mode / toggle_streaming (kill-switch)
  models/
    election.rb                    # current/governor/council, council_seat_breakdown,
                                   #   live_streaming?, record_trend_point!, KEEP_TREND_POINTS=300
  services/
    results_snapshot.rb            # payload เดียว: fallback + กราฟ + zone detail
    results_broadcaster.rb         # Turbo Stream 4 region → stream "results"
    snapshot_publisher.rb          # เขียน results.json → S3 (max-age=5)
    result_writer.rb               # เขียนคะแนนต่อ zone (StaleVotesError guard)
    ingest/                        # Client (HTTP) + EctAdapter (parse/validate)
    news/fetcher.rb                # WordPress RSS + og:image
  jobs/
    ingest_poll_job.rb             # recurring 30 วิ: fetch → write → broadcast → publish
    snapshot_archive_job.rb        # archive snapshot ย้อนหลัง
  javascript/controllers/
    fallback_controller.js         # poll CDN snapshot (safety-net)
    council_controller.js          # poll 15 วิ (สก.)
    trend_chart_controller.js      # กราฟจาก server series
config/
  deploy.yml                       # Kamal: host, proxy(CF cert), accessories(db/redis)
  recurring.yml                    # ingest_poll governor/council ทุก 30 วิ
  cable.yml                        # Action Cable redis adapter, prefix bkk2026_production
  application.rb                   # config.time_zone = "Bangkok"
docs/
  architecture.md                  # ← ไฟล์นี้
  runbooks/election-night.md       # checklist + scaling + kill-switch
```

---

## 12. Architecture Decisions (ADR log)

บันทึกการตัดสินใจหลัก + เหตุผล (spec รายฟีเจอร์อยู่ที่ `docs/superpowers/specs/`)

| # | การตัดสินใจ | เหตุผล |
|---|-------------|--------|
| 1 | **Edge-first** — CF cache HTML + CloudFront cache snapshot JSON | origin O(1) ไม่ผูกกับจำนวนคนดู → box เล็กก็รับหมื่นได้ |
| 2 | **Dual data path** — WS push (A) + CDN poll fallback (B) วิ่งคู่ | latency ต่ำ + resilient; ถ้า WS เงียบ poll snapshot อัตโนมัติ |
| 3 | **Kill-switch** `live_streaming` flag | ปิด WS ตอนพีค → ทุกคนตกไป CDN → origin O(1) (เพดานจริง) |
| 4 | **Ingest all-or-nothing** (`EctAdapter` reject ถ้าเขตไม่ครบ) | ห้ามเขียนทับข้อมูลดีด้วย payload ไม่ครบ/พัง |
| 5 | **Votes monotonic** (`StaleVotesError`) | คะแนนขึ้นได้อย่างเดียว — กันข้อมูลย้อนหลัง |
| 6 | **Solid Queue ใน Puma** (`SOLID_QUEUE_IN_PUMA`) | single-host เรียบง่าย; clustered → supervisor รันใน master ครั้งเดียว (ไม่ run job ซ้ำ) |
| 7 | **Countdown splash client-side gated** (เวลา+localStorage) | cache-safe (logic ไม่อยู่ฝั่ง server) + anti-flash inline script |
| 8 | **Consent ปล่อยให้ Consentrix CMP จัดการ** (ไม่ใส่ GA Consent Mode default-deny) | เรียบง่าย; CMP บล็อก/ปลด tracking เอง |
| 9 | **Blue-green cutover** (disk clone → deploy+reboot test → สลับ CF DNS → ปิดเครื่องเก่า) | zero downtime; verify เครื่องใหม่เต็มที่ก่อน cut |
| 10 | **WS tuning** = FD limit + clustered Puma (ไม่เน้น CPU/PG) | คอขวด WS จริงคือ FD (default 1024) + RAM ไม่ใช่ CPU; PG โหลดต่ำเพราะ edge-first |
| 11 | **FD/tuning ผ่าน entrypoint `ulimit` + accessory `cmd`** (ไม่พึ่ง Kamal options) | เชื่อถือได้ 100%, reboot-proof, ไม่ขึ้นกับ Kamal version |
| 12 | **Load test ต้อง distributed** (หลาย source IP) | Huawei anti-DDoS throttle flood จาก IP เดียวที่ ~2000 → single-IP วัด capacity ไม่ได้ |

---

## 13. ของที่เหลือ / ต้องจำ (ณ 28 มิ.ย. 2026)

- **เปิด `governor=api` เมื่อเริ่มนับจริง** — ตอนนี้ governor=manual, votes=0 (council=api แล้ว); ไม่มี admin user บน prod → flip ผ่าน `kamal app exec --reuse "bin/rails runner 'Election.governor.update!(data_mode: :api)'"`
- **whitelist Cloudflare IP ranges** ใน Huawei Cloud security group — กัน anti-DDoS throttle CF→origin + lock origin ให้รับเฉพาะ CF (security)
- ไม่มี admin user บน prod — ถ้าจะใช้ Admin UI (kill-switch/กรอกมือ) ต้องสร้างก่อน (`User.create!`)
