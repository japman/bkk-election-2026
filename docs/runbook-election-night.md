# Runbook คืนเลือกตั้ง 28 มิ.ย. 2569

## ENV ที่ production ต้องมี

| ENV | ใช้ทำอะไร |
|---|---|
| `DATABASE_URL` | RDS PostgreSQL |
| `REDIS_URL` | ElastiCache — ActionCable pub/sub |
| `ECT_API_URL` | endpoint API กกต./พาร์ทเนอร์ |
| `SNAPSHOT_BUCKET` | S3 bucket ของ results.json (CloudFront ชี้มา) |
| `PUBLIC_ORIGIN` | origin ของเว็บ เช่น https://election.dailynews.co.th |
| `NEWS_FEED_URL` | RSS เว็บหลัก (มี default) |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | สร้าง admin user ครั้งแรก |
| `RAILS_MASTER_KEY` | credentials |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | สิทธิ์เขียน S3 (หรือใช้ instance profile แทน) |

## เกณฑ์ load test ต้องผ่านก่อน 21 มิ.ย. (spec §8.3)
- `k6 run loadtest/ws.js` — 6,000 WS ค้าง 10 นาที, error <1%
- `k6 run loadtest/poll.js` — 800 req/s, p95 <1 วิ, fail <1%
- broadcast ถึง browser จริง <5 วิ (เปิด browser ระหว่างรัน k6 แล้วป้อนคะแนนผ่าน admin)

## ก่อนปิดหีบ (ก่อน 17:00)
- [ ] ตรวจ ENV ครบทั้ง 2 app instances
- [ ] `bin/rails db:seed` แล้ว — 50 เขต + รายชื่อผู้สมัครจริง + admin users
- [ ] Solid Queue ทำงาน: log มี `ingest_poll` ทุก 30 วิ
- [ ] เปิดหน้าเว็บผ่าน CloudFront — WS ต่อได้ (DevTools เห็น /cable status 101)
- [ ] ทดสอบ admin: กรอกคะแนนเขตทดสอบ → หน้า public อัปเดต <5 วิ → แก้กลับ
- [ ] `curl -s <CDN>/results.json | jq .updated_at` — อัปเดตจริง

## ระหว่างนับคะแนน
- ดู log ingest: บรรทัด `[ingest] rejected` = API ส่งของเพี้ยน → ตรวจกับพาร์ทเนอร์
- **API ล่ม/ค้าง:** job retry สั้นๆ เองแล้วรอรอบใหม่ทุก 30 วิ — ถ้าเกิน ~5 นาทีไม่ฟื้น:
  เข้า /admin → "สลับเป็นโหมดกรอกมือ" → ทีมข่าวกรอกจากแหล่งสำรอง
- **API ฟื้น:** เทียบตัวเลข API ล่าสุดกับที่กรอกมือ → สลับกลับโหมด API
  (ถ้าตัวเลข API ต่ำกว่าที่กรอกมือ ingest จะ reject เขตนั้น — ถูกต้องแล้ว
  รอ API ตามทันหรือคงโหมด manual ต่อ)
- **กรอกผิด:** /admin/revisions ดูค่าเดิม → เปิดเขตนั้นกรอกค่าที่ถูก → บันทึก
- **เว็บช้า/WS เต็ม:** ไม่ต้องทำอะไร — client ตกไป polling CDN เอง (เช็คว่า
  results.json บน CloudFront อัปเดต: `curl -s <CDN>/results.json | jq .updated_at`)
- **broadcast พังแต่เว็บต้องไปต่อ:** snapshot ยัง publish ทุกรอบ — ผู้ชมได้ข้อมูลช้าสุด ~10-15 วิ ผ่าน fallback

## หลังปิดระบบ
- [ ] export ResultRevision เก็บเป็นหลักฐาน: `bin/rails runner 'puts ResultRevision.order(:id).to_json' > revisions-backup.json`
- [ ] สลับ election.status เป็น "closed"

## Deploy ขึ้น UAT/Prod
1. push ขึ้น main (หรือ tag `v*`) → GitHub Actions build + push image ขึ้น GHCR อัตโนมัติ
   (repo ต้องมี GitHub remote ก่อน: `git remote add origin git@github.com:<ORG>/<REPO>.git`)
2. เติมค่า `<SERVER_IP>`, `<ELECTION_DOMAIN>`, org/username ใน `config/deploy.yml`
   และ secrets ใน `.kamal/secrets` (อย่า commit ค่าจริง)
3. ครั้งแรก: `bin/kamal setup` — ครั้งถัดไป: `bin/kamal deploy`
4. ตรวจ: `bin/kamal app logs -f` + เปิด https://<ELECTION_DOMAIN>/up ต้องได้ 200
5. seed production: `bin/kamal app exec 'bin/rails db:seed'` แล้วสร้าง admin user
   ตามคอมเมนต์ใน db/seeds.rb
6. smoke test เครื่องเดียวก่อนขึ้นจริง: `docker compose -f compose.uat.yml -p bkk-uat up`
