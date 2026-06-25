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

  it "renders a single grey row for merged independents" do
    e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    e.candidates.create!(number: 1, name: "A", party: "อิสระ", color: "#aa0000")
    e.candidates.create!(number: 2, name: "B", party: "อิสระ", color: "#00aa00")
    z1 = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "z2", grid_col: 2, grid_row: 1)
    ResultWriter.new(z1, source: "api").apply!({ 1 => 10 })
    ResultWriter.new(z2, source: "api").apply!({ 2 => 10 })
    get "/council"
    expect(response.body).to include("#888888")
    expect(response.body.scan("party-name").size).to eq(1)
  end
end
