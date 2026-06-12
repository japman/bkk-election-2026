require "rails_helper"

RSpec.describe Ingest::Client do
  around do |example|
    old = ENV["ECT_API_URL"]
    ENV["ECT_API_URL"] = "https://partner.example/results"
    example.run
    ENV["ECT_API_URL"] = old
  end

  it "returns the body on success" do
    allow(Net::HTTP).to receive(:get_response)
      .and_return(double(Net::HTTPOK, body: "{}").tap { |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      })
    expect(described_class.fetch).to eq("{}")
  end

  it "raises FetchError on non-200" do
    allow(Net::HTTP).to receive(:get_response)
      .and_return(double(Net::HTTPBadGateway, code: "502").tap { |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      })
    expect { described_class.fetch }.to raise_error(Ingest::Client::FetchError, /502/)
  end
end
