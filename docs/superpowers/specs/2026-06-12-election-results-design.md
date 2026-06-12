# Design: เว็บไซต์ประกาศผลเลือกตั้งผู้ว่าฯ กทม. 2569 (Realtime)

**วันที่:** 12 มิถุนายน 2026
**สถานะ:** อนุมัติโดยทีมแล้ว (brainstorming session)
**Deadline:** ระบบพร้อมใช้งานจริง 21 มิถุนายน 2026 — วันเลือกตั้ง 28 มิถุนายน 2026

## 1. เป้าหมายและขอบเขต

เว็บไซต์ของ Dailynews สำหรับรายงานผลการเลือกตั้งผู้ว่าราชการกรุงเทพมหานคร 2569
แบบ realtime ในคืนเลือกตั้ง

**Requirements หลัก:**

- อัปเดตผลแบบ push ถึงหน้าจอภายใน <5 วินาทีหลังข้อมูลเข้าระบบ
- รองรับ 6,000 concurrent users เป็นอย่างต่ำ (และ degrade อย่างนุ่มนวลถ้าเกิน)
- ข้อมูลหลักมาจาก API ของ กกต./พาร์ทเนอร์ (มี spec แล้ว) + ทีมงานกรอกมือผ่าน
  admin ได้เมื่อ API มีปัญหา
- แสดง: อันดับผู้สมัคร + คะแนนรวม, แผนที่ 50 เขต, กราฟ/สถิติ, ข่าวจาก Dailynews
- ขอบเขตคือผลผู้ว่าฯ เท่านั้น แต่ data model ออกแบบเผื่อการเลือกตั้งอื่นในอนาคต
  (เช่น ส.ก., ส.ส.)

**นอกขอบเขต (ตัดออกเพื่อ deadline 9 วัน):**

- ระบบสมาชิก/ล็อกอินฝั่งผู้ชม, comment, ระบบแจ้งเตือน push notification
- ผลการเลือกตั้งชนิดอื่นใน phase นี้
- CMS สำหรับข่าว (ดึงจากเว็บหลัก dailynews.co.th แทน)

## 2. Tech Stack

- **Framework:** Ruby on Rails เวอร์ชันล่าสุด (8.x) — ทีมถนัด Rails;
  ยืนยันแล้วว่าไม่ใช้ Rails 4.0.5 เพราะ EOL และไม่มี ActionCable
- **Database:** PostgreSQL
- **Realtime:** ActionCable (WebSocket) + Turbo Streams, Redis เป็น pub/sub adapter
- **Background jobs:** Solid Queue
- **Frontend:** Rails views + Hotwire (Turbo/Stimulus) — JS น้อยที่สุด
- **Infra:** AWS — ALB + app instances ×2, RDS, ElastiCache, S3 + CloudFront
  (มี Huawei Cloud เป็นทางเลือกสำรองขององค์กร แต่ phase นี้ deploy บน AWS เจ้าเดียว)

## 3. สถาปัตยกรรม (แนวทาง A ที่เลือก)

Rails monolith เดียว + WebSocket push + fallback polling ผ่าน CDN

```
กกต./พาร์ทเนอร์ API ──> Ingest Worker (poll ทุก 30 วิ)
                              │ validate
                              v
       Admin Panel ──────> PostgreSQL ──> Redis pub/sub ──> ActionCable ×2 ──> Browser ×6000
       (กรอกมือ/override)        │                              (Turbo Streams over WS)
                              v
                    Snapshot Publisher ──> results.json บน S3 + CloudFront
                                                 ^
                          Browser ที่ WS หลุด ── poll ทุก 10 วิ (fallback อัตโนมัติ)
```

**ทางเลือกที่พิจารณาแล้วไม่เลือก:**

- *Static JSON + polling ล้วน:* ทนโหลดสุดแต่ไม่ใช่ push จริง (สดที่ ~5-15 วิ) —
  เก็บไว้เป็นกลไก fallback ในแนวทาง A แทน
- *Managed realtime (Pusher/Ably):* push ง่ายแต่เพิ่ม vendor นอก AWS/Huawei,
  มีค่าใช้จ่าย และข้อมูลเลือกตั้งวิ่งผ่าน third-party

**เหตุผลที่ 6,000 connections ไม่ใช่ปัญหา:** ข้อมูลเป็น broadcast เดียวกันทุกคน
(ไม่มี per-user state) ActionCable 2 instances รับได้สบาย และ client ที่ต่อ WS
ไม่ได้จะตกไปใช้ polling CDN เองโดยอัตโนมัติ — โหลดเกินคาดจึงทำให้ "ช้าลงไม่กี่วิ"
ไม่ใช่ "ล่ม"

## 4. Layout หน้าเว็บ

- **Desktop:** Dashboard แบ่งซ้าย-ขวา — ซ้าย: แผนที่ 50 เขต (interactive),
  ขวา: leaderboard ผู้สมัครทุกอันดับพร้อมคะแนนสด; แถวล่าง: กราฟ + ข่าว Dailynews;
  header ติดบน: ชื่องาน + % นับแล้ว + สัญลักษณ์ LIVE
- **Mobile:** ยุบเป็นแนวตั้งเรียงตามความสำคัญ — อันดับ 1-3 การ์ดใหญ่ →
  อันดับถัดไปแบบตาราง → แผนที่ → กราฟ → ข่าว
- ทุกตัวเลขที่เปลี่ยนต้องมี visual feedback (เช่น highlight วูบ) ให้รู้ว่าสด

## 5. Components

1. **Ingest Worker** — job ดึงผลจาก API ทุก 30 วิ → validate (ดู §7) →
   เขียน PostgreSQL → ถ้าเปลี่ยน: broadcast Turbo Streams + เรียก Snapshot Publisher
2. **Public Site** — หน้าเดียว (Rails views + Hotwire) รับอัปเดตผ่าน WS,
   JS ฝั่ง client สลับไป poll CDN เมื่อ WS หลุดและพยายามต่อใหม่เบื้องหลัง
3. **Admin Panel** — `/admin` ป้องกันด้วยบัญชีทีมงาน username/password
   (Rails 8 authentication generator — ไม่ใช้ gem ภายนอก); กรอก/แก้คะแนนรายเขต;
   ปุ่มสลับโหมด `api` ⇄ `manual` (โหมด manual: ข้อมูลกรอกมือ override ข้อมูล API
   จนกว่าจะสลับกลับ); ทุกการแก้ต้อง confirm และถูกบันทึกใน ResultRevision
4. **Snapshot Publisher** — เขียน `results.json` ขึ้น S3 (CloudFront TTL 5 วิ)
   ทุกครั้งที่ข้อมูลเปลี่ยน — เป็นทั้ง fallback ของ public site และแหล่งข้อมูลกราฟ

## 6. Data Model

```
Election   — id, name, election_date, status        # เผื่อเลือกตั้งอื่นในอนาคต
Candidate  — election_id, number, name, party, photo, color
Zone       — election_id, code, name, geometry      # 50 เขต กทม. + พิกัดสำหรับแผนที่
VoteResult — zone_id, candidate_id, votes,
             source (api|manual), updated_at
ZoneStat   — zone_id, eligible_voters, turnout, bad_ballots, no_vote,
             counted_percent, source
ResultRevision — บันทึกทุกการเปลี่ยนแปลงของ VoteResult/ZoneStat:
             ค่าเดิม, ค่าใหม่, ที่มา (api|admin), ผู้แก้, เวลา
```

- คะแนนรวมทั้ง กทม. = SUM จาก 50 เขต (คำนวณสด ไม่เก็บซ้ำ — ไม่มีโอกาสเลขไม่ตรงกัน)
- ข่าว Dailynews ดึงผ่าน RSS/API ของเว็บหลัก ไม่เก็บในระบบนี้

## 7. Error Handling

| สถานการณ์ | การรับมือ |
|---|---|
| API กกต. ล่ม/timeout | Retry แบบ exponential backoff; หน้าเว็บแสดงข้อมูลล่าสุด + เวลาอัปเดต (ไม่จอขาว); banner เตือนใน admin; ทีมสลับโหมด manual ได้ทันที |
| API ส่งข้อมูลเพี้ยน | Validate ก่อนบันทึกเสมอ: คะแนนต้องไม่ลดลง (ลดได้เฉพาะ admin ยืนยัน), เขตครบ, ตัวเลขเป็นบวก, format ตรง spec — ไม่ผ่าน = reject + log ให้ทีมตรวจ |
| WebSocket หลุด | Client fallback เป็น poll CDN ทุก 10 วิอัตโนมัติ + ต่อ WS ใหม่เบื้องหลัง |
| โหลดพีคเกิน 6,000 | ทุกอย่างอยู่หลัง CloudFront; WS เต็ม → client ใหม่ใช้ polling แทน (graceful degradation) |
| Admin กรอกผิด | ResultRevision ย้อนกลับได้ทุกรายการ + ต้อง confirm ก่อนบันทึก |

## 8. Testing

1. **Unit/Request specs (RSpec)** — validation ของ ingest, การรวมคะแนน, admin override, การสลับโหมด
2. **Ingest contract tests** — fixture ตาม spec API กกต. จริง ครอบคลุมทุกกรณีข้อมูลเพี้ยนใน §7
3. **Load test (k6)** — 6,000 WebSocket + 8,000 polling clients บน staging — ต้องผ่านก่อน 21 มิ.ย.
4. **Dress rehearsal กับทีมข่าว** — จำลองคืนเลือกตั้งเต็มรูปแบบ: ป้อนคะแนนทีละรอบ, ซ้อม API ล่มกลางคัน, ซ้อมสลับโหมด manual

## 9. ความเสี่ยงหลัก

- **เวลา 9 วัน** — ทุกการตัดสินใจเลือกทางที่ build เร็วก่อน (monolith, Hotwire,
  ไม่มี SPA framework)
- **Spec API พาร์ทเนอร์คลาดเคลื่อนจากของจริง** — แยก ingest adapter เป็น class เดียว
  เปลี่ยน mapping ได้โดยไม่กระทบส่วนอื่น + โหมด manual เป็นตาข่ายนิรภัยสุดท้าย
