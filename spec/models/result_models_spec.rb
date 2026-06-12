require "rails_helper"

RSpec.describe VoteResult do
  let(:election) { build_election(zones: 1, candidates: 1) }
  let(:zone) { election.zones.first }
  let(:candidate) { election.candidates.first }

  it "rejects negative votes" do
    vr = VoteResult.new(zone:, candidate:, votes: -1, source: "api")
    expect(vr).not_to be_valid
  end

  it "enforces one row per zone+candidate" do
    VoteResult.create!(zone:, candidate:, votes: 10, source: "api")
    expect(VoteResult.new(zone:, candidate:, votes: 20, source: "api")).not_to be_valid
  end

  it "rejects a candidate from a different election" do
    other = build_election(zones: 1, candidates: 1)
    vr = VoteResult.new(zone:, candidate: other.candidates.first, votes: 1, source: "api")
    expect(vr).not_to be_valid
  end
end

RSpec.describe ZoneStat do
  it "rejects counted_percent over 100" do
    zone = build_election(zones: 1, candidates: 1).zones.first
    expect(ZoneStat.new(zone:, counted_percent: 101, source: "api")).not_to be_valid
  end
end

RSpec.describe ResultRevision do
  it "stores old and new values for a recordable" do
    election = build_election(zones: 1, candidates: 1)
    vr = VoteResult.create!(zone: election.zones.first, candidate: election.candidates.first, votes: 10, source: "api")
    rev = ResultRevision.create!(recordable: vr, old_values: { "votes" => nil },
                                 new_values: { "votes" => 10 }, source: "api")
    expect(rev.reload.new_values).to eq("votes" => 10)
    expect(rev.recordable).to eq(vr)
  end
end
