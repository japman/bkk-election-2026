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
end
