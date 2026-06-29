# Static results archive — design

วันที่: 2026-06-29 · สถานะ: approved (แนวทาง 2) · ผู้ทำ: subagent (TDD)

## เป้าหมาย
แปลงผลเลือกตั้ง **frozen** (governor + council, `data_mode=manual`) เป็นหน้า **static HTML self-contained** เก็บบน S3 (root ของ bucket `bkk-election-2026`, เสิร์ฟผ่าน CloudFront เดิม) ไว้อ้างอิงระยะยาว แชร์ได้ SEO ดี — **อยู่ได้แม้ปลด Rails app**

## Scope (อนุมัติแล้ว)
- **2 หน้า** mirror live: `index.html` (ผู้ว่าฯ) + `council.html` (สก) — แท็บสลับเป็น **ลิงก์ relative**
- **Full frozen replica**: hero ผู้ชนะ · leaderboard · แผนที่ 50 เขต **คลิกดูรายเขตได้** · กราฟเทรนด์ (governor) · สรุปที่นั่ง (council) · ปุ่มสลับธีม · ข่าว 5 อัน frozen
- **ตัด**: live poll/flash · countdown · news สด (แทนด้วย frozen) · Consentrix/GA · importmap/Stimulus
- ข้อมูลนิ่ง ฝัง inline — ไม่ fetch/poll

## Architecture (แนวทาง 2 — แยกจาก live ทั้งหมด)
ไฟล์ใหม่:
```
app/services/archive_builder.rb          # ตรรกะหลัก (เทสได้) — render + inline + rewrite + (upload)
lib/tasks/archive.rake                   # archive:build
app/views/layouts/archive.html.erb       # standalone layout
app/views/archive/governor.html.erb      # reuse partial เดิม (hero/leaderboard/map/stats/trend)
app/views/archive/council.html.erb       # reuse council partial (map/seats/zone_detail)
app/views/archive/_header.html.erb        # header เฉพาะ archive: โลโก้ + แท็บ(ลิงก์) + theme toggle + "นับ X%"
app/views/archive/_news_frozen.html.erb  # ข่าว 5 อัน static (title/excerpt/thumb absolute/link)
```
**live views/partials เดิมห้ามแก้** (archive reuse partial เพื่อ visual fidelity แต่ layout/header/JS แยก)

### ArchiveBuilder (service)
`ArchiveBuilder.new(base_url:, out_dir: "tmp/archive").build!(upload: false)` →
1. render แต่ละหน้า: `ApplicationController.render(template: "archive/governor", layout: "archive", assigns: { election: Election.governor, snapshot_json: ResultsSnapshot.new(g).as_json.to_json, base_url:, news_items: News::Fetcher.latest(limit: 5) })`
   - ⚠️ **ไม่มี request context** → layout ห้ามใช้ `request.*`; OG/canonical ใช้ `@base_url`
2. **inline CSS**: อ่าน `app/assets/stylesheets/application.css` (31KB, ไฟล์เดียว ไม่มี @import) → `<style>` ใน layout
3. **embed data**: snapshot JSON ของหน้านั้น → `<script type="application/json" id="snapshot">` (governor=results.json, council=results-council.json)
4. **rewrite asset URLs**: regex แทนทุก `/images/…` และ `/assets/…` (Propshaft fingerprint ของโลโก้) → relative `assets/…`; เก็บ set ของไฟล์ที่อ้างถึงไว้ upload
5. เขียนไฟล์ลง `out_dir/` (`index.html`, `council.html`, `assets/…`) — ใช้ **preview**
6. ถ้า `upload: true`: put ขึ้น S3 root + `assets/` (ใช้ `Aws::S3::Client` แบบเดียวกับ `SnapshotPublisher`, `cache_control` HTML สั้นๆ / รูปยาว, content_type ถูก) — bucket จาก `ENV["SNAPSHOT_BUCKET"]`

### Layout (`archive.html.erb`)
- `<head>`: title/description นิ่ง · OG/Twitter (`og:url=@base_url(+council.html)`, `og:image=assets/og-cover.jpg` แบบ absolute `@base_url/assets/og-cover.jpg`, summary_large_image) · canonical · theme-color · robots index,follow · **Google Fonts `<link>` คงไว้** · inline `<style>` · **ไม่มี** importmap/Consentrix/GA
- `<body>`: render header partial + `yield` + footer (credits เดิม: consentrix.odds.team / odt.co.th) + `<script type="application/json" id="snapshot">` + inline `<script>` (JS ด้านล่าง)

### Inline JS (vanilla, อยู่ใน layout)
อ่าน `JSON.parse(document.getElementById("snapshot").textContent)` แล้ว:
- **คลิกเขต→รายเขต**: hook `.tile[data-zone-code]` → หาเขตใน JSON (`zones[]` governor / `districts[]` council) → เติม panel `.zone-detail` (ชื่อ/counted/stats/rows) — logic แปลงจาก `zone_detail_controller.js` + `council_controller.js` (เอาส่วน `render`/`show` มา, ตัด fetch)
- **กราฟเทรนด์** (governor): วาด SVG จาก `data.trend` ครั้งเดียว — logic จาก `trend_chart_controller.js#draw` (ตัด poll); หา element ที่ live ใช้ `data-controller="trend-chart"` แล้ว reuse
- **theme toggle**: localStorage `bkk2026-theme` (เหมือน `theme_controller.js`)

## Data flow
frozen DB → `ResultsSnapshot` (governor_json/council_json) → embed inline → vanilla JS อ่าน render รายเขต/กราฟ (ไม่มี network). รูปผู้สมัคร/โลโก้ relative `assets/` (co-located). ข่าว frozen ที่ build-time (thumb เป็น absolute dailynews URL).

## Error handling / robustness
- ArchiveBuilder รับ `base_url` (เช่น `https://d2qyp6lcqlvau.cloudfront.net` หรือโดเมนสุดท้าย) — ไม่ hardcode
- ถ้า `News::Fetcher.latest` คืน `[]` (feed ล่ม) → ข้าม section ข่าว ไม่ทำให้ build พัง
- upload เป็น opt-in (`upload: true`); rake default = local-only preview
- rewrite ครอบคลุมทั้ง `/images/` (raw photo_url) และ `/assets/` (Propshaft โลโก้/og-cover)

## Rake task (`lib/tasks/archive.rake`)
`archive:build` — `BASE_URL=<url>` (จำเป็น), `LOCAL_ONLY=1` (default behavior = เขียน tmp/archive + upload; LOCAL_ONLY ข้าม upload). พิมพ์ path ไฟล์ + ขนาด + จำนวนรูป + (ถ้า upload) S3 keys

## Testing (TDD)
- `spec/services/archive_builder_spec.rb` (stub S3, ไม่ยิงจริง):
  - render governor → HTML มีชื่อผู้ชนะ (`ชัชชาติ`), มี `<script type="application/json" id="snapshot">` ที่ parse ได้, มี leaderboard/แผนที่ tile ครบ 50
  - **self-contained**: ไม่มี `importmap`/`turbo`/`stimulus`/`data-turbo`/`http://` ของ app; asset URL เป็น relative `assets/` ทั้งหมด (ไม่มี `/images/`,`/assets/` ที่ขึ้นต้น `/`)
  - inline `<style>` มีเนื้อ CSS (เช็คความยาว/selector รู้จัก)
  - council → มี districts + seats; embed `results-council.json`
  - ไม่ raise แม้ไม่มี request (assert ไม่มี `request.` ใน output / render สำเร็จ)
  - `upload: true` กับ S3 double → `put_object` ถูกเรียกด้วย key `index.html`,`council.html`, content_type ถูก
- **manual verify** (ผู้ทำหลัก): build LOCAL_ONLY → เปิด `tmp/archive/index.html` ในเบราว์เซอร์ → คลิกเขต/สลับธีม/แท็บ ทำงาน รูปขึ้น

## ขั้นตอน subagent
1. TDD: เขียน spec ArchiveBuilder ก่อน → implement service + layout + views + header + news partial + inline JS จนเขียว
2. build `LOCAL_ONLY` ลง `tmp/archive/` — **ยังไม่ upload S3, ไม่ deploy**
3. รัน full suite ให้เขียว
4. รายงานไฟล์ที่เพิ่ม + ผล build + วิธีเปิด preview
```
ยังไม่ commit · ยังไม่ upload S3 · ยังไม่ deploy — main loop verify เองก่อน
```
