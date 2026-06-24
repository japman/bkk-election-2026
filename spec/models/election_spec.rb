require "rails_helper"

RSpec.describe Election do
  it "selects the latest election of each kind" do
    gov = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
    cou = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    expect(Election.governor).to eq(gov)
    expect(Election.council).to eq(cou)
    expect(Election.current).to eq(gov) # alias for governor
  end
end
