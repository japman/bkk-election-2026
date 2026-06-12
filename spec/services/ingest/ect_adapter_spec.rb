require "rails_helper"

RSpec.describe Ingest::EctAdapter do
  let(:raw) { Rails.root.join("spec/fixtures/ingest/valid.json").read }

  def parse(raw, codes: %w[01 02], numbers: [1, 2])
    described_class.parse(raw, expected_zone_codes: codes, known_numbers: numbers)
  end

  it "normalizes a valid payload" do
    r = parse(raw)
    expect(r).to be_ok
    expect(r.data["01"][:votes]).to eq(1 => 18230, 2 => 15110)
    expect(r.data["01"][:stats]).to eq(eligible_voters: 91200, turnout: 55700,
                                       bad_ballots: 512, no_vote: 701, counted_percent: 72.5)
  end

  it "rejects when zones are missing" do
    r = parse(raw, codes: %w[01 02 03])
    expect(r).not_to be_ok
    expect(r.errors.join).to include("03")
  end

  it "rejects negative votes" do
    bad = JSON.parse(raw)
    bad["zones"][0]["results"][0]["votes"] = -5
    expect(parse(bad.to_json)).not_to be_ok
  end

  it "rejects unknown candidate numbers" do
    expect(parse(raw, numbers: [1])).not_to be_ok
  end

  it "rejects invalid JSON" do
    r = parse("ไม่ใช่ json")
    expect(r).not_to be_ok
    expect(r.errors.join).to include("invalid JSON")
  end
end
