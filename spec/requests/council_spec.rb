require "rails_helper"

RSpec.describe "Council dashboard", type: :request do
  it "renders the council page" do
    Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    get "/council"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("สก")
  end

  it "renders the district map grid and a seats summary container" do
    c = Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    c.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    get "/council"
    expect(response.body).to include('class="map-grid"')
    expect(response.body).to include("council-seats")
  end

  it "includes the district detail panel container" do
    Election.create!(name: "C", election_date: Date.new(2026,6,28), kind: "council")
    get "/council"
    expect(response.body).to include('data-council-target="panel"')
  end
end
