require "rails_helper"

RSpec.describe Ingest::Client do
  around do |example|
    old = ENV["ECT_API_URL"]
    ENV["ECT_API_URL"] = "https://partner.example/results"
    example.run
    ENV["ECT_API_URL"] = old
  end

  it "returns the body on success" do
    response = double(Net::HTTPOK, body: "{}")
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(Net::HTTP).to receive(:start).and_yield(double("http", get: response))
    expect(described_class.fetch).to eq("{}")
  end

  it "raises FetchError on non-200" do
    response = double(Net::HTTPBadGateway, code: "502")
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
    allow(Net::HTTP).to receive(:start).and_yield(double("http", get: response))
    expect { described_class.fetch }.to raise_error(Ingest::Client::FetchError, /502/)
  end

  it "wraps network errors in FetchError" do
    allow(Net::HTTP).to receive(:start).and_raise(SocketError.new("getaddrinfo failed"))
    expect { described_class.fetch }.to raise_error(Ingest::Client::FetchError, /getaddrinfo/)
  end
end
