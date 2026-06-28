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
    expect(result.warnings).to be_empty
    a46 = result.data["46"]
    expect(a46[:votes][7]).to eq(33913)
    expect(a46[:stats]).to eq(
      eligible_voters: 172765, turnout: 112117,
      bad_ballots: 2177, no_vote: 1089, counted_percent: 84.55
    )
  end

  # --- fatal: not a real results payload -> reject the whole batch ---
  it "rejects (fatal) when success is not true" do
    expect(parse(payload.merge("success" => false))).not_to be_ok
  end

  it "rejects (fatal) when data.areas is not an array" do
    payload["data"]["areas"] = "nope"
    expect(parse(payload)).not_to be_ok
  end

  # --- non-fatal: results stream in incrementally -> write the rest, warn ---
  it "tolerates a missing area and still writes the others" do
    dropped = payload["data"]["areas"].pop
    code = format("%02d", dropped["area_number"])
    result = parse(payload)
    expect(result).to be_ok
    expect(result.data).not_to have_key(code)
    expect(result.data.keys.length).to eq(49)
    expect(result.warnings.join).to match(/missing areas/)
  end

  it "skips only the area with an unknown candidate_id" do
    bad  = payload["data"]["areas"][0]
    code = format("%02d", bad["area_number"])
    bad["results"][0]["candidate_id"] = "not-a-known-uuid"
    result = parse(payload)
    expect(result).to be_ok
    expect(result.data).not_to have_key(code)
    expect(result.data.keys.length).to eq(49)
    expect(result.warnings.join).to match(/unknown candidate_id/)
  end

  it "skips only the area with a negative vote" do
    bad  = payload["data"]["areas"][0]
    code = format("%02d", bad["area_number"])
    bad["results"][0]["votes"] = -5
    result = parse(payload)
    expect(result).to be_ok
    expect(result.data).not_to have_key(code)
    expect(result.warnings.join).to match(/non-negative integer/)
  end

  it "skips only the area with counted_percent out of range" do
    bad  = payload["data"]["areas"][0]
    code = format("%02d", bad["area_number"])
    bad["metadata"]["coverage_percentage"] = 150
    result = parse(payload)
    expect(result).to be_ok
    expect(result.data).not_to have_key(code)
    expect(result.warnings.join).to match(/coverage_percentage out of range/)
  end
end
