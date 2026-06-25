require "rails_helper"

RSpec.describe Election do
  it "selects the latest election of each kind" do
    gov = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
    cou = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    expect(Election.governor).to eq(gov)
    expect(Election.council).to eq(cou)
    expect(Election.current).to eq(gov) # alias for governor
  end

  describe "#record_trend_point!" do
    it "captures one point with all candidates' totals (string keys)" do
      e = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
      e.candidates.create!(number: 1, name: "A", party: "พรรคก", color: "#0E8A45")
      e.candidates.create!(number: 2, name: "B", party: "พรรคข", color: "#1a73e8")
      z = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
      ResultWriter.new(z, source: "api").apply!({ 1 => 100, 2 => 40 })

      expect { e.record_trend_point! }.to change { e.trend_points.count }.by(1)
      pt = TrendPoint.order(:id).last
      expect(pt.votes).to eq({ "1" => 100, "2" => 40 })
      expect(pt.captured_at).to be_within(5.seconds).of(Time.current)
    end

    it "prunes to the most recent KEEP_TREND_POINTS rows" do
      e = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
      e.candidates.create!(number: 1, name: "A", party: "ก", color: "#0E8A45")
      (Election::KEEP_TREND_POINTS + 5).times { e.record_trend_point! }
      expect(e.trend_points.count).to eq(Election::KEEP_TREND_POINTS)
    end
  end

  describe "#council_seat_breakdown" do
    it "merges same-party winners and greys multi-colour parties (อิสระ)" do
      e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
      e.candidates.create!(number: 1, name: "A", party: "อิสระ", color: "#aa0000")
      e.candidates.create!(number: 2, name: "B", party: "อิสระ", color: "#00aa00")
      e.candidates.create!(number: 3, name: "C", party: "พรรคก", color: "#0000aa")
      z1 = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
      z2 = e.zones.create!(code: "02", name: "z2", grid_col: 2, grid_row: 1)
      z3 = e.zones.create!(code: "03", name: "z3", grid_col: 3, grid_row: 1)
      ResultWriter.new(z1, source: "api").apply!({ 1 => 10 })
      ResultWriter.new(z2, source: "api").apply!({ 2 => 10 })
      ResultWriter.new(z3, source: "api").apply!({ 3 => 10 })

      rows = e.council_seat_breakdown
      ind = rows.find { |r| r[:party] == "อิสระ" }
      expect(ind[:seats]).to eq(2)
      expect(ind[:color]).to eq("#888888")
      expect(rows.find { |r| r[:party] == "พรรคก" }[:color]).to eq("#0000aa")
      expect(rows.first[:seats]).to be >= rows.last[:seats] # sorted desc
    end
  end
end
