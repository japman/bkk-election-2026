module ElectionSetup
  # สร้าง election พร้อม candidates/zones ขั้นต่ำสำหรับ spec
  def build_election(zones: 2, candidates: 2)
    election = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28), status: "live")
    candidates.times do |i|
      election.candidates.create!(number: i + 1, name: "ผู้สมัคร #{i + 1}", party: "พรรค #{i + 1}", color: "#0E8A45")
    end
    zones.times do |i|
      election.zones.create!(code: format("%02d", i + 1), name: "เขต #{i + 1}", grid_col: i + 1, grid_row: 1)
    end
    election
  end
end

RSpec.configure { |config| config.include ElectionSetup }
