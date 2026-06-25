require "rails_helper"

RSpec.describe "Public page edge-caching", type: :request do
  include ElectionSetup
  before { allow(News::Fetcher).to receive(:latest).and_return([]) }

  shared_examples "an edge-cacheable public page" do |path|
    it "sends public short-lived Cache-Control + no session cookie (#{path})" do
      get path
      cc = response.headers["Cache-Control"].to_s
      expect(cc).to include("public")
      expect(cc).to include("max-age=5")
      expect(cc).to include("stale-while-revalidate=30")
      expect(response.headers["Set-Cookie"].to_s).not_to include("_dailynews_election_bkk2026_session")
    end

    it "omits the CSRF meta tag (#{path})" do
      get path
      expect(response.body).not_to include('name="csrf-token"')
    end
  end

  context "governor /" do
    before { build_election(zones: 1, candidates: 1) }
    include_examples "an edge-cacheable public page", "/"
  end

  context "council /council" do
    before { Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council") }
    include_examples "an edge-cacheable public page", "/council"
  end
end
