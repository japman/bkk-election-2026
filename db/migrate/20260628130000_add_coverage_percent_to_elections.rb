class AddCoveragePercentToElections < ActiveRecord::Migration[8.1]
  # % นับคะแนนจริงจาก ECT (data.coverage.percentage = stationsReported/totalStations)
  # แทนการเฉลี่ย coverage รายเขต ซึ่งถ่วงน้ำหนักผิด (ทุกเขตเท่ากัน). Default 0 →
  # Election#counted_percent fallback เป็นเฉลี่ยรายเขตจนกว่าจะ ingest ครั้งแรก.
  def change
    add_column :elections, :coverage_percent, :decimal, precision: 5, scale: 2, default: 0, null: false
  end
end
