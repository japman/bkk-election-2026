# SEO meta + og:image + logo swap — design

วันที่: 2026-06-27 · สถานะ: approved (user: image=JPG, copy=approved, logo=header-only)

## 1. og:image
- ต้นฉบับ: PNG 1280×720 (984KB, ภาพ "NEXT LEVEL 2026 — ผลคะแนนเรียลไทม์")
- **บีบเป็น JPG ~150-250KB** (`public/og-cover.jpg`) — โหลดเร็ว, รองรับทุกแพลตฟอร์ม
- อ้างเป็น absolute URL ผ่าน `ENV["PUBLIC_ORIGIN"]` (fallback `request.base_url` สำหรับ dev)
- ขนาด og:image:width=1280 height=720

## 2. SEO meta (เพิ่มใน `app/views/layouts/application.html.erb` `<head>` — ปัจจุบันไม่มีเลย)
- **title default** → `ผลเลือกตั้งผู้ว่าฯ กทม. และ ส.ก. 2569 เรียลไทม์ | เดลินิวส์` (override ได้ด้วย `content_for(:title)`)
- `<meta name="description">` → `เกาะติดผลนับคะแนนเลือกตั้งผู้ว่าฯ กทม. และ ส.ก. 2569 แบบเรียลไทม์ รายเขต พร้อมแผนที่ กราฟ และสรุปที่นั่ง โดยทีมข่าวเดลินิวส์`
- **Open Graph:** `og:type=website`, `og:site_name=เดลินิวส์`, `og:title`, `og:description`, `og:image` (+width/height), `og:url` (= `request.original_url`), `og:locale=th_TH`
- **Twitter Card:** `twitter:card=summary_large_image`, `twitter:title`, `twitter:description`, `twitter:image`
- `<link rel="canonical" href=request.original_url>`, `<meta name="theme-color">`, `<meta name="robots" content="index, follow">`
- ใช้ helper ภายใน layout (ไม่มี logic ซับซ้อน) — title/description มี constant default, override ได้ผ่าน `content_for`/`@meta_description` ถ้าต้องการในอนาคต

## 3. Logo (header public เท่านั้น)
- `app/views/dashboard/_site_header.html.erb`: แทน `<div class="logo">DAILY<span>NEWS</span></div>` ด้วย `<%= image_tag "logo-dn-pink-04.webp", alt: "เดลินิวส์", class: "logo-img" %>`
- โลโก้สีชมพูล้วน พื้นโปร่งใส → ใช้ได้ทั้ง light/dark (ไม่ต้อง variant)
- CSS: `.brand` → `align-items:center`; `.logo-img{height:30px;width:auto;display:block}`; mobile (`max-width:600px`) height 22px. คง `.brand .event` เดิม (ชื่อหน้า)
- ไม่แตะ `.auth-brand` (admin login) ตามที่ตกลง

## Testing
- request spec (`spec/requests/dashboard_spec.rb`): หน้า `/` มี `property="og:image"`, og:title, twitter:card, meta description, `rel="canonical"`, และ `logo-dn-pink-04.webp` ใน header; ไม่มี text logo `>DAILY<` แล้ว
- verify: `public/og-cover.jpg` มีจริง + ขนาดเหมาะ; build/asset serve 200; curl prod ตรวจ meta หลัง deploy
- social: ตรวจ og ด้วย FB Sharing Debugger / LINE หลัง deploy (manual)
