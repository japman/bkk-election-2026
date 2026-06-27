# Countdown splash + credit footer — design

วันที่: 2026-06-27 · สถานะ: approved (user "ตามนี้")

## 1. Countdown splash (overlay)

**เป้าหมาย:** บังหน้า dashboard ด้วย splash นับถอยหลัง จนถึง **08:00 น. 28 มิ.ย. 2569**
(public ไม่เห็นผลก่อนเวลาประกาศจริง) — ทีมงาน bypass ได้ด้วยการคลิก 10 ครั้ง

### พฤติกรรม
- **แสดง** เมื่อ `now < TARGET` และยังไม่เคยถูกปิดในเครื่องนี้
- **ปิดอัตโนมัติ** เมื่อ `now >= TARGET` (08:00 28 มิ.ย. 2569 +07) — ไม่แสดงอีกเลย (time-gate)
- **ปิดด้วยมือ** คลิกที่ overlay ครบ **10 ครั้ง** → ปิด + จำใน `localStorage["bkk2026-countdown-dismissed"]="1"` (ไม่เด้งอีกในเครื่องนั้น)
- **anti-flash:** overlay ตั้ง `hidden` เป็น default; inline `<script>` ท้าย element เช็คเวลา+localStorage แล้ว `el.hidden=false` แบบ synchronous ก่อน paint → ไม่มี flash ของ dashboard (ก่อน 8:00) และไม่มี flash ของ splash (หลัง 8:00 / ปิดแล้ว)
- **cache-safe:** logic อยู่ฝั่ง client ล้วน (เทียบ `Date.now()` กับ target) → ไม่กระทบ Cloudflare cache 5 วิ

### โครงสร้าง
- `app/views/dashboard/show.html.erb`: เพิ่ม overlay markup (บนสุด) + inline anti-flash script
- `app/javascript/controllers/countdown_controller.js`: ticking ทุก 1 วิ (วัน:ชม:นาที:วิ), auto-close, นับคลิก, localStorage — values `target` (ISO string), `clicksToClose` (default 10); targets `days/hours/minutes/seconds`
- `app/assets/stylesheets/application.css`: `.countdown-splash` (fixed inset:0, z-index:1000, dark-glass via var), `.countdown-splash[hidden]{display:none}`, fade-out gated ด้วย `prefers-reduced-motion`

### ui-ux-pro-max ที่ใช้
- `consistency` (ใช้ theme เดิม Midnight Glass + CSS vars), `contrast-readability` (≥4.5:1), `reduced-motion`, `number-tabular` (ตัวเลข timer), `duration-timing` (fade ≤300ms)
- trade-off: blocking overlay ไม่มีปุ่มปิดที่เห็นชัด (เจตนา = pre-launch gate); 10-click = escape สำหรับทีมงาน

## 2. Credit footer

ต่อท้าย `<footer>` เดิมใน `show.html.erb` เพิ่มบรรทัด credit:
- `Consent by` → link `https://consentrix.odds.team`
- `Developed by` → link `https://odt.co.th`
- เปิด tab ใหม่ (`target="_blank" rel="noopener"`), สี muted, **underline** (ไม่สื่อด้วยสีอย่างเดียว ตาม `color-not-only`), contrast ผ่าน

## Testing
- request spec (`spec/requests/dashboard_spec.rb`): footer มี link consentrix.odds.team + odt.co.th; overlay markup (`data-controller="countdown"` + target + หัวข้อ) render ใน HTML
- JS behavior (ticking/10-click/localStorage) ไม่มี JS test harness ในโปรเจกต์ → verify ด้วยมือใน browser หลัง deploy
