require "rails_helper"

RSpec.describe Election do
  it "requires name and election_date" do
    expect(Election.new).not_to be_valid
  end

  it "defaults data_mode to api" do
    e = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28))
    expect(e).to be_api
  end

  it "returns the newest election as current" do
    Election.create!(name: "เก่า", election_date: Date.new(2022, 5, 22))
    new_e = Election.create!(name: "ใหม่", election_date: Date.new(2026, 6, 28))
    expect(Election.current).to eq(new_e)
  end
end

RSpec.describe Candidate do
  it "enforces unique number per governor election at the database level" do
    e = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28))
    e.candidates.create!(number: 1, name: "ก", color: "#000000")
    expect { e.candidates.create!(number: 1, name: "ข", color: "#111111") }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end

RSpec.describe Zone do
  it "enforces unique code per election" do
    e = Election.create!(name: "ทดสอบ", election_date: Date.new(2026, 6, 28))
    e.zones.create!(code: "01", name: "พระนคร", grid_col: 5, grid_row: 5)
    expect(e.zones.build(code: "01", name: "ดุสิต", grid_col: 5, grid_row: 4)).not_to be_valid
  end
end
