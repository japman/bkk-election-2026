require "rails_helper"

RSpec.describe Ingest::Client do
  BASE = "https://media.election.in.th/api/media/elections/bkk-governor-2026".freeze

  around do |ex|
    old_url = ENV["ECT_API_URL"]; old_tok = ENV["ECT_API_TOKEN"]
    ENV["ECT_API_URL"] = BASE; ENV["ECT_API_TOKEN"] = "test-token"
    ex.run
    ENV["ECT_API_URL"] = old_url; ENV["ECT_API_TOKEN"] = old_tok
  end

  it "fetches area results with bearer auth and parses JSON" do
    stub = stub_request(:get, "#{BASE}/auto?level=area")
      .with(headers: { "Authorization" => "Bearer test-token" })
      .to_return(status: 200, body: { success: true, data: { areas: [] } }.to_json)
    expect(described_class.fetch_results).to eq("success" => true, "data" => { "areas" => [] })
    expect(stub).to have_been_requested
  end

  it "fetches candidates" do
    stub_request(:get, "#{BASE}/auto/candidates")
      .with(headers: { "Authorization" => "Bearer test-token" })
      .to_return(status: 200, body: { success: true, data: { candidates: [] } }.to_json)
    expect(described_class.fetch_candidates).to include("success" => true)
  end

  it "raises FetchError on a non-success status (e.g. 403)" do
    stub_request(:get, "#{BASE}/auto?level=area").to_return(status: 403, body: "denied")
    expect { described_class.fetch_results }.to raise_error(Ingest::Client::FetchError, /403/)
  end

  it "raises FetchError on invalid JSON" do
    stub_request(:get, "#{BASE}/auto?level=area").to_return(status: 200, body: "not-json")
    expect { described_class.fetch_results }.to raise_error(Ingest::Client::FetchError, /JSON/)
  end
end
