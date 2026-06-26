require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  include ElectionSetup
  include ActiveSupport::Testing::TimeHelpers

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

  it "renders the updated time in UTC+7 (Bangkok)" do
    build_election(zones: 1, candidates: 1)
    travel_to(Time.utc(2026, 6, 26, 0, 35, 0)) do
      get "/"
      expect(response.body).to include("07:35")
    end
  end

  it "renders the map without zoom controls" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).not_to include("map-zoom")
    expect(response.body).to include('class="map-grid"')
  end

  it "does not fetch news on the main results page (lazy frame)" do
    build_election(zones: 1, candidates: 1)
    expect(News::Fetcher).not_to receive(:latest)
    get "/"
    expect(response.body).to include('id="news_panel"')
    expect(response.body).to include('src="/news"')
    expect(response.body).to include('loading="lazy"')
    expect(response.body).to include("กำลังโหลดข่าว")
  end

  it "renders the news frame at /news" do
    get "/news"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('turbo-frame id="news_panel"')
    expect(response.body).to include("เกาะติดจาก Dailynews")
  end

  it "keeps the results page up even if the news source fails (news is isolated in the frame)" do
    allow(News::Fetcher).to receive(:latest).and_raise(SocketError)
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response).to have_http_status(:ok)
  end
end
