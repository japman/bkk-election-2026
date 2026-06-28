# Stack tuning for 6000 WS — design (8 core / 16 GB target)

วันที่: 2026-06-28 (election day) · สถานะ: approved
เป้าหมาย: รองรับ ~6000 concurrent WebSocket บน box ใหม่ **8 vCPU / 16 GB** (resize จาก 2vCPU/3.4GB)

## ลำดับสำคัญ (เตรียม config ไว้ก่อน — deploy หลัง resize)
ห้าม deploy ค่าเหล่านี้ลง box 2vCPU/3.4GB เดิม (shared_buffers 2GB + 5 workers = OOM)
1. เตรียม config (PR นี้) → commit ไว้ **ยังไม่ deploy**
2. resize box → 8c/16G (Huawei Cloud, reboot)
3. deploy config → 4. ยิง k6 (`loadtest/ws.js` 6000 WS) ตรวจ RAM/CPU/FD

## การเปลี่ยนแปลง

### 1. FD limit (nofile) — ⭐ critical
ปัจจุบัน soft=1024 (hard=524288) → ตันที่ ~1000 WS ไม่ว่า box ใหญ่แค่ไหน
- ตั้ง `ulimit -n 65536` ใน `bin/docker-entrypoint` (bash, hard=524288 อนุญาตให้ดัน soft โดยไม่ต้อง privilege) — เชื่อถือได้ 100% ไม่ขึ้นกับว่า Kamal รองรับ `options.ulimit` ไหม; worker ที่ fork จาก master สืบทอด limit นี้

### 2. Puma (clustered)
- `config/puma.rb`: เพิ่ม `workers ENV.fetch("WEB_CONCURRENCY", 0).to_i` (0 = single mode เดิม → dev/test/CI ไม่กระทบ)
- env: `WEB_CONCURRENCY=5` (เหลือ ~3 core ให้ PG/Redis/SolidQueue/OS), `RAILS_MAX_THREADS=5`
- ไม่ใช้ `preload_app!` (เลี่ยงความซับซ้อน fork+multi-DB; RAM 16GB เหลือพอ) — แต่ละ worker โหลดเอง
- `plugin :solid_queue` รันใน master ครั้งเดียว (ไม่ซ้ำต่อ worker) → ปลอดภัยกับ cluster

### 3. Postgres (accessory cmd)
- `cmd: postgres -c shared_buffers=2GB -c effective_cache_size=6GB -c work_mem=8MB -c maintenance_work_mem=256MB`
- แก้ `effective_cache_size` (เดิม 5GB บน box 3.4GB = ผิด), ดัน shared_buffers 160MB→2GB
- โหลด PG ต่ำอยู่แล้ว (edge-first) → ส่วนใหญ่เป็น correctness

### 4. Redis (accessory cmd)
- `cmd: redis-server --appendonly no --maxmemory 1gb --maxmemory-policy allkeys-lru`
- Redis ใช้แค่ ActionCable pub/sub (ephemeral) → ปิด AOF ลด disk I/O; maxmemory เป็น safety cap
- (RDB ปล่อย default — dataset เล็กมาก ไม่กระทบ)

### 5. somaxconn (host sysctl — รันบน host ตอน deploy, ไม่อยู่ใน repo)
- `sysctl -w net.core.somaxconn=65535` (เดิม 4096) + persist ใน `/etc/sysctl.d/` — เผื่อ connection storm

## Rollback
- ทุกอย่างเป็น config: revert commit + redeploy. PG/Redis cmd กลับ default. WEB_CONCURRENCY unset → single mode.
- ถ้า WS ยังไม่ไหว → kill-switch (Live WS OFF) → ทุกคน poll CDN (results.json) → origin ~0

## Verify
- หลัง deploy: `ulimit -Sn` ใน container = 65536; `docker exec db psql -c "show shared_buffers"` = 2GB; redis `CONFIG GET appendonly` = no; `WEB_CONCURRENCY` workers รันจริง (`ps`/puma log)
- k6: `k6 run -e WS_URL=wss://bkk-election-2026.dailynews.co.th/cable -e SIGNED_STREAM=<token> loadtest/ws.js` → ws 101 ≥ 99%, ดู RAM/CPU บน host
