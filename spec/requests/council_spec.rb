require "rails_helper"

RSpec.describe "Council dashboard", type: :request do
  it "renders the council page" do
    Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    get "/council"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("สก")
  end
end
