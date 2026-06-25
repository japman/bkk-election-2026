require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  include ElectionSetup

  before { allow(News::Fetcher).to receive(:latest).and_return([]) }

  it "renders leaderboard and one tile per zone" do
    build_election(zones: 3, candidates: 2)
    get "/"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ผู้สมัคร 1")
    expect(response.body.scan('class="tile"').size).to eq(3)
  end

  it "renders an empty state when no election exists" do
    get "/"
    expect(response.body).to include("ยังไม่เปิดรายงานผล")
  end

  it "is publicly accessible without login" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response).to have_http_status(:ok)
  end

  it "renders the theme toggle" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).to include("theme-toggle")
  end

  it "subscribes to the results stream when live streaming is on (default)" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).to include("turbo-cable-stream-source")
  end

  it "drops the stream and polls immediately when live streaming is off" do
    e = build_election(zones: 1, candidates: 1)
    e.update!(live_streaming: false)
    get "/"
    expect(response.body).not_to include("turbo-cable-stream-source")
    expect(response.body).to include('data-fallback-stale-after-value="0"')
  end
end
