# 50 เขต กทม. — [ชื่อ, grid_col, grid_row] เรียงตามผัง cartogram
# code = ลำดับในผังนี้ (01-50) — adapter เป็นคนแปลงรหัสเขตของ กกต. มาเป็น code นี้
ZONES = [
  [ "ดอนเมือง", 6, 1 ], [ "สายไหม", 7, 1 ], [ "คลองสามวา", 9, 1 ], [ "หนองจอก", 10, 1 ],
  [ "หลักสี่", 6, 2 ], [ "บางเขน", 7, 2 ], [ "ลาดพร้าว", 8, 2 ], [ "บึงกุ่ม", 9, 2 ],
  [ "คันนายาว", 10, 2 ], [ "มีนบุรี", 11, 2 ],
  [ "ทวีวัฒนา", 1, 3 ], [ "ตลิ่งชัน", 2, 3 ], [ "บางพลัด", 4, 3 ], [ "บางซื่อ", 5, 3 ],
  [ "จตุจักร", 6, 3 ], [ "ห้วยขวาง", 7, 3 ], [ "วังทองหลาง", 8, 3 ], [ "บางกะปิ", 9, 3 ],
  [ "สะพานสูง", 10, 3 ], [ "ลาดกระบัง", 11, 3 ],
  [ "หนองแขม", 1, 4 ], [ "บางแค", 2, 4 ], [ "ภาษีเจริญ", 3, 4 ], [ "บางกอกน้อย", 4, 4 ],
  [ "ดุสิต", 5, 4 ], [ "พญาไท", 6, 4 ], [ "ราชเทวี", 7, 4 ], [ "ดินแดง", 8, 4 ],
  [ "สวนหลวง", 9, 4 ], [ "ประเวศ", 10, 4 ],
  [ "บางบอน", 1, 5 ], [ "จอมทอง", 2, 5 ], [ "บางกอกใหญ่", 3, 5 ], [ "ธนบุรี", 4, 5 ],
  [ "พระนคร", 5, 5 ], [ "ป้อมปราบฯ", 6, 5 ], [ "ปทุมวัน", 7, 5 ], [ "วัฒนา", 8, 5 ],
  [ "พระโขนง", 9, 5 ],
  [ "บางขุนเทียน", 1, 6 ], [ "ทุ่งครุ", 2, 6 ], [ "ราษฎร์บูรณะ", 3, 6 ], [ "คลองสาน", 4, 6 ],
  [ "สัมพันธวงศ์", 5, 6 ], [ "บางรัก", 6, 6 ], [ "สาทร", 7, 6 ], [ "คลองเตย", 8, 6 ],
  [ "บางนา", 9, 6 ],
  [ "บางคอแหลม", 5, 7 ], [ "ยานนาวา", 6, 7 ]
].freeze

# ข้อมูลจำลอง — แทนที่ด้วยรายชื่อจริงเมื่อ กกต. ประกาศ
CANDIDATES = [
  [ 1, "วรา สินธุเดช", "อิสระ", "#0E8A45" ],
  [ 2, "เกรียงไกร บุญมาก", "ไทยนคร", "#C42B2B" ],
  [ 3, "พิมพ์ลดา เกียรติกุล", "ก้าวกรุง", "#F47B20" ],
  [ 4, "อรอนงค์ แสงทอง", "อิสระ", "#0FA3A3" ],
  [ 5, "สมศักดิ์ พงศ์ธารา", "ประชารักษ์", "#1B6CC4" ],
  [ 6, "ประพันธ์ ศรีวงศ์", "พลังเมือง", "#8B6B2E" ],
  [ 7, "ชลธร มหานที", "อิสระ", "#7A4FBF" ],
  [ 8, "มานพ ตั้งตรง", "อิสระ", "#5B6770" ]
].freeze

election = Election.find_or_create_by!(name: "เลือกตั้งผู้ว่าราชการกรุงเทพมหานคร 2569") do |e|
  e.election_date = Date.new(2026, 6, 28)
  e.status = "scheduled"
end

ZONES.each_with_index do |(name, col, row), i|
  election.zones.find_or_create_by!(code: format("%02d", i + 1)) do |z|
    z.name = name
    z.grid_col = col
    z.grid_row = row
  end
end

CANDIDATES.each do |number, name, party, color|
  election.candidates.find_or_create_by!(number: number) do |c|
    c.name = name
    c.party = party
    c.color = color
  end
end

puts "Seeded: #{election.name} — #{election.zones.count} zones, #{election.candidates.count} candidates"

if Rails.env.development?
  User.find_or_create_by!(email_address: ENV.fetch("ADMIN_EMAIL", "admin@dailynews.local")) do |u|
    u.password = ENV.fetch("ADMIN_PASSWORD", "election2026")
  end
  puts "Admin user: #{ENV.fetch('ADMIN_EMAIL', 'admin@dailynews.local')}"
end
# production: สร้าง admin ครั้งแรกด้วย
#   bin/rails runner 'User.create!(email_address: ENV.fetch("ADMIN_EMAIL"), password: ENV.fetch("ADMIN_PASSWORD"))'
