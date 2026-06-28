# 50 เขต กทม. — [ชื่อ, grid_col, grid_row]. เรียงตาม "รหัสเขตทางการของ กกต./กทม."
# (พระนคร=01 ... บางบอน=50) เพราะ EctAdapter ใช้ area_number จาก API เป็น Zone.code
# ตรงๆ (format "%02d") — ดังนั้น code ที่ N ต้องเป็นเขตทางการที่ N เป๊ะ ไม่งั้นผลคะแนน
# จะลงผิดเขต. grid_col/grid_row = ตำแหน่งช่องบนผัง cartogram (คงเดิมต่อเขต — แผนที่เหมือนเดิม)
Object.send(:remove_const, :ZONES) if defined?(ZONES)
ZONES = [
  [ "พระนคร", 5, 5 ], [ "ดุสิต", 5, 4 ], [ "หนองจอก", 10, 1 ], [ "บางรัก", 6, 6 ],
  [ "บางเขน", 7, 2 ], [ "บางกะปิ", 9, 3 ], [ "ปทุมวัน", 7, 5 ], [ "ป้อมปราบฯ", 6, 5 ],
  [ "พระโขนง", 9, 5 ], [ "มีนบุรี", 11, 2 ],
  [ "ลาดกระบัง", 11, 3 ], [ "ยานนาวา", 6, 7 ], [ "สัมพันธวงศ์", 5, 6 ], [ "พญาไท", 6, 4 ],
  [ "ธนบุรี", 4, 5 ], [ "บางกอกใหญ่", 3, 5 ], [ "ห้วยขวาง", 7, 3 ], [ "คลองสาน", 4, 6 ],
  [ "ตลิ่งชัน", 2, 3 ], [ "บางกอกน้อย", 4, 4 ],
  [ "บางขุนเทียน", 1, 6 ], [ "ภาษีเจริญ", 3, 4 ], [ "หนองแขม", 1, 4 ], [ "ราษฎร์บูรณะ", 3, 6 ],
  [ "บางพลัด", 4, 3 ], [ "ดินแดง", 8, 4 ], [ "บึงกุ่ม", 9, 2 ], [ "สาทร", 7, 6 ],
  [ "บางซื่อ", 5, 3 ], [ "จตุจักร", 6, 3 ],
  [ "บางคอแหลม", 5, 7 ], [ "ประเวศ", 10, 4 ], [ "คลองเตย", 8, 6 ], [ "สวนหลวง", 9, 4 ],
  [ "จอมทอง", 2, 5 ], [ "ดอนเมือง", 6, 1 ], [ "ราชเทวี", 7, 4 ], [ "ลาดพร้าว", 8, 2 ],
  [ "วัฒนา", 8, 5 ], [ "บางแค", 2, 4 ],
  [ "หลักสี่", 6, 2 ], [ "สายไหม", 7, 1 ], [ "คันนายาว", 10, 2 ], [ "สะพานสูง", 10, 3 ],
  [ "วังทองหลาง", 8, 3 ], [ "คลองสามวา", 9, 1 ], [ "บางนา", 9, 6 ], [ "ทวีวัฒนา", 1, 3 ],
  [ "ทุ่งครุ", 2, 6 ], [ "บางบอน", 1, 5 ]
].freeze

# ข้อมูลจำลอง — แทนที่ด้วยรายชื่อจริงเมื่อ กกต. ประกาศ
Object.send(:remove_const, :CANDIDATES) if defined?(CANDIDATES)
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

election = Election.find_or_create_by!(name: "เลือกตั้งผู้ว่าราชการกรุงเทพมหานคร 2569", kind: "governor") do |e|
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

council = Election.find_or_create_by!(name: "เลือกตั้งสมาชิกสภากรุงเทพมหานคร 2569", kind: "council") do |e|
  e.election_date = Date.new(2026, 6, 28)
  e.status = "scheduled"
end
ZONES.each_with_index do |(name, col, row), i|
  council.zones.find_or_create_by!(code: format("%02d", i + 1)) do |z|
    z.name = name; z.grid_col = col; z.grid_row = row
  end
end
puts "Seeded: #{council.name} — #{council.zones.count} zones"

if Rails.env.development?
  User.find_or_create_by!(email_address: ENV.fetch("ADMIN_EMAIL", "admin@dailynews.local")) do |u|
    u.password = ENV.fetch("ADMIN_PASSWORD", "election2026")
  end
  puts "Admin user: #{ENV.fetch('ADMIN_EMAIL', 'admin@dailynews.local')}"
end
# production: สร้าง admin ครั้งแรกด้วย
#   bin/rails runner 'User.create!(email_address: ENV.fetch("ADMIN_EMAIL"), password: ENV.fetch("ADMIN_PASSWORD"))'
