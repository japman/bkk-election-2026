require "rails_helper"

RSpec.describe Candidate do
  let(:election) { build_election(zones: 0, candidates: 1) }

  it "stores an external_id" do
    c = election.candidates.first
    c.update!(external_id: "uuid-abc")
    expect(c.reload.external_id).to eq("uuid-abc")
  end

  it "rejects a duplicate non-null external_id" do
    election.candidates.first.update!(external_id: "uuid-dup")
    dup = election.candidates.build(number: 99, name: "x", external_id: "uuid-dup")
    expect(dup).to be_invalid
    expect(dup.errors[:external_id]).to be_present
  end

  it "allows multiple null external_ids" do
    election.candidates.create!(number: 98, name: "a")
    election.candidates.create!(number: 97, name: "b")
    expect(election.candidates.where(external_id: nil).count).to be >= 2
  end

  it "stores a party_logo_url" do
    c = build_election(zones: 0, candidates: 1).candidates.first
    c.update!(party_logo_url: "/images/parties/prachachon.png")
    expect(c.reload.party_logo_url).to eq("/images/parties/prachachon.png")
  end

  it "allows the same number in different zones for council, but not twice in one zone" do
    e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    z1 = e.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "ข", grid_col: 2, grid_row: 1)
    e.candidates.create!(number: 1, name: "a", color: "#111", zone: z1)
    expect { e.candidates.create!(number: 1, name: "b", color: "#222", zone: z2) }.not_to raise_error
    expect { e.candidates.create!(number: 1, name: "c", color: "#333", zone: z1) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
