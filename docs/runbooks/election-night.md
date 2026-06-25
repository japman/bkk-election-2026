# Election-night Runbook

## ก่อนเริ่มนับคะแนน
- [ ] ยืนยัน Cloudflare Cache Rules ทำงาน: `curl -sI https://bkk-election-2026.dailynews.co.th/` (ครั้งที่ 2 → `cf-cache-status: HIT`), `/admin` → bypass/DYNAMIC
- [ ] ยืนยัน WS: WS upgrade `/cable` (Origin โดเมนจริง) → 101
- [ ] ยืนยันหน้า สก poll: `/council` DevTools เห็น fetch `results-council.json` ทุก 15วิ
- [ ] Admin > Live WebSocket = ON

## Scale host (ก่อนพีค)
1. scale Huawei instance → ≥ 4 vCPU / 8 GB (8 vCPU ถ้าคาดหมื่น+ และเปิด WS)
2. ตั้ง env แล้ว reboot app: `WEB_CONCURRENCY=2` (4 vCPU) หรือ `3` (8 vCPU); คง `RAILS_MAX_THREADS=3`
3. ตรวจ Postgres `max_connections` ≥ WEB_CONCURRENCY × RAILS_MAX_THREADS + queue + cache/cable (default 100 พอ)

## ถ้า origin/RAM ตึงระหว่างพีค
- เข้า Admin > กด "ปิด WS (โหมด peak)" → visitor ใหม่เลิกต่อ WebSocket ภายใน ~5วิ, ทุกคน poll CDN แทน (ภาระ origin O(1))
- กลับมากด "เปิด WS" เมื่อโหลดลด

## หลังจบงาน
- คืนค่า host/WEB_CONCURRENCY; Live WS = ON
