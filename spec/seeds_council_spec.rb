require "rails_helper"

RSpec.describe "council seed" do
  it "creates a council election with 50 zones" do
    load Rails.root.join("db/seeds.rb")
    c = Election.council
    expect(c).to be_present
    expect(c.zones.count).to eq(50)
    expect(c.zones.pluck(:code)).to include("01", "50")
    load Rails.root.join("db/seeds.rb") # idempotent
    expect(Election.where(kind: "council").count).to eq(1)
  end
end
