# spec/services/ingest/ect_adapter_spec.rb
require "rails_helper"

RSpec.describe Ingest::EctAdapter do
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_area_results.json").read) }
  let(:candidate_map) do
    JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_candidates.json").read)
        .dig("data", "candidates").to_h { |c| [c["id"], c["number"]] }
  end
  let(:zone_codes) { (1..50).map { |n| format("%02d", n) } }

  def parse(p) = described_class.parse(p, expected_zone_codes: zone_codes, candidate_map: candidate_map)

  it "normalizes the real 50-area payload" do
    result = parse(payload)
    expect(result).to be_ok
    expect(result.data.keys).to match_array(zone_codes)
    a46 = result.data["46"]
    expect(a46[:votes][7]).to eq(33913)
    expect(a46[:stats]).to eq(
      eligible_voters: 172765, turnout: 112117,
      bad_ballots: 2177, no_vote: 1089, counted_percent: 84.55
    )
  end

  it "rejects when success is not true" do
    expect(parse(payload.merge("success" => false))).not_to be_ok
  end

  it "rejects an unknown candidate_id" do
    payload["data"]["areas"][0]["results"][0]["candidate_id"] = "not-a-known-uuid"
    result = parse(payload)
    expect(result).not_to be_ok
    expect(result.errors.join).to match(/unknown candidate_id/)
  end

  it "rejects a missing area" do
    payload["data"]["areas"].pop
    expect(parse(payload).errors.join).to match(/missing areas/)
  end

  it "rejects a negative vote" do
    payload["data"]["areas"][0]["results"][0]["votes"] = -5
    expect(parse(payload).errors.join).to match(/non-negative integer/)
  end

  it "rejects counted_percent out of range" do
    payload["data"]["areas"][0]["metadata"]["coverage_percentage"] = 150
    expect(parse(payload).errors.join).to match(/coverage_percentage out of range/)
  end
end
