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
    expect(response.body).to include('id="news_panel"')
    expect(response.body).to include("เกาะติดจาก Dailynews")
  end

  it "keeps the results page up even if the news source fails (news is isolated in the frame)" do
    allow(News::Fetcher).to receive(:latest).and_raise(SocketError)
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response).to have_http_status(:ok)
  end

  it "renders the credit footer with consentrix + odt links" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).to include('href="https://consentrix.odds.team"')
    expect(response.body).to include("consentrix.odds.team")
    expect(response.body).to include('href="https://odt.co.th"')
    expect(response.body).to include("odt.co.th")
  end

  it "renders the countdown splash hidden by default, JS-gated to 08:00 28 Jun" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).to include('id="countdown"')
    expect(response.body).to include('data-controller="countdown"')
    expect(response.body).to include('data-countdown-target-value="2026-06-28T08:00:00+07:00"')
    expect(response.body).to include('data-countdown-clicks-to-close-value="10"')
    expect(response.body).to include("08:00")
  end

  it "renders SEO description, Open Graph, and Twitter Card meta" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).to include('<meta name="description"')
    expect(response.body).to include('property="og:title"')
    expect(response.body).to include('property="og:description"')
    expect(response.body).to include('property="og:image"')
    expect(response.body).to include("og-cover.jpg")
    expect(response.body).to include('property="og:image:width" content="1280"')
    expect(response.body).to include('name="twitter:card" content="summary_large_image"')
    expect(response.body).to include('rel="canonical"')
  end

  it "uses the Dailynews image logo in the header (not the text logo)" do
    build_election(zones: 1, candidates: 1)
    get "/"
    expect(response.body).to include("logo-dn-pink-04")
    expect(response.body).not_to include("DAILY<span>NEWS</span>")
  end
end
