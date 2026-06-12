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
end
