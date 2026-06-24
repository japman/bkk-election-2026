require "rails_helper"

RSpec.describe Ingest::Client do
  let(:base) { "https://media.election.in.th/api/media/elections/bkk-governor-2026" }

  around do |ex|
    saved = ENV.slice("ECT_API_URL", "ECT_API_TOKENS", "ECT_API_TOKEN")
    ENV["ECT_API_URL"] = base
    ENV["ECT_API_TOKENS"] = "tok-a,tok-b"
    ENV.delete("ECT_API_TOKEN")
    ex.run
    %w[ECT_API_URL ECT_API_TOKENS ECT_API_TOKEN].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
  end

  it "fetches area results with bearer auth and parses JSON" do
    # either configured token is acceptable (order is randomized to spread load)
    %w[tok-a tok-b].each do |t|
      stub_request(:get, "#{base}/auto?level=area")
        .with(headers: { "Authorization" => "Bearer #{t}" })
        .to_return(status: 200, body: { success: true, data: { areas: [] } }.to_json)
    end
    expect(described_class.fetch_results).to eq("success" => true, "data" => { "areas" => [] })
  end

  it "fetches candidates" do
    %w[tok-a tok-b].each do |t|
      stub_request(:get, "#{base}/auto/candidates")
        .with(headers: { "Authorization" => "Bearer #{t}" })
        .to_return(status: 200, body: { success: true, data: { candidates: [] } }.to_json)
    end
    expect(described_class.fetch_candidates).to include("success" => true)
  end

  it "fails over to another token when one is rate-limited (429)" do
    stub_request(:get, "#{base}/auto?level=area")
      .with(headers: { "Authorization" => "Bearer tok-a" })
      .to_return(status: 429, body: "rate limited")
    stub_request(:get, "#{base}/auto?level=area")
      .with(headers: { "Authorization" => "Bearer tok-b" })
      .to_return(status: 200, body: { success: true, data: { areas: [] } }.to_json)
    expect(described_class.fetch_results).to eq("success" => true, "data" => { "areas" => [] })
  end

  it "raises FetchError when every token fails" do
    %w[tok-a tok-b].each do |t|
      stub_request(:get, "#{base}/auto?level=area")
        .with(headers: { "Authorization" => "Bearer #{t}" }).to_return(status: 429)
    end
    expect { described_class.fetch_results }
      .to raise_error(Ingest::Client::FetchError, /all 2 ECT token\(s\) failed/)
  end

  it "raises FetchError on invalid JSON" do
    ENV["ECT_API_TOKENS"] = "only-one"
    stub_request(:get, "#{base}/auto?level=area")
      .with(headers: { "Authorization" => "Bearer only-one" })
      .to_return(status: 200, body: "not-json")
    expect { described_class.fetch_results }.to raise_error(Ingest::Client::FetchError, /JSON/)
  end

  it "still supports the legacy single ECT_API_TOKEN" do
    ENV.delete("ECT_API_TOKENS")
    ENV["ECT_API_TOKEN"] = "legacy"
    stub_request(:get, "#{base}/auto?level=area")
      .with(headers: { "Authorization" => "Bearer legacy" })
      .to_return(status: 200, body: { success: true, data: { areas: [] } }.to_json)
    expect(described_class.fetch_results).to include("success" => true)
  end

  it "raises when no token is configured" do
    ENV.delete("ECT_API_TOKENS"); ENV.delete("ECT_API_TOKEN")
    expect { described_class.fetch_results }
      .to raise_error(Ingest::Client::FetchError, /no ECT API token/)
  end
end
