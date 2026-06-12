require "rails_helper"

RSpec.describe "Election aggregation" do
  it "sums leaderboard votes across zones and sorts descending" do
    e = build_election(zones: 2, candidates: 2)
    z1, z2 = e.zones.order(:code).to_a
    c1, c2 = e.candidates.order(:number).to_a
    VoteResult.create!(zone: z1, candidate: c1, votes: 100, source: "api")
    VoteResult.create!(zone: z2, candidate: c1, votes: 50, source: "api")
    VoteResult.create!(zone: z1, candidate: c2, votes: 400, source: "api")

    board = e.leaderboard.to_a
    expect(board.first).to eq(c2)
    expect(board.first.total_votes).to eq(400)
    expect(board.second.total_votes).to eq(150)
    expect(e.total_votes).to eq(550)
  end

  it "averages counted_percent over all zones (zones without stats count as 0)" do
    e = build_election(zones: 2, candidates: 1)
    ZoneStat.create!(zone: e.zones.first, counted_percent: 80, source: "api")
    expect(e.counted_percent).to eq(40.0)
  end

  it "sums zone stats into a summary" do
    e = build_election(zones: 2, candidates: 1)
    z1, z2 = e.zones.to_a
    ZoneStat.create!(zone: z1, eligible_voters: 900, turnout: 500, bad_ballots: 4, no_vote: 6, counted_percent: 50, source: "api")
    ZoneStat.create!(zone: z2, eligible_voters: 800, turnout: 300, bad_ballots: 2, no_vote: 8, counted_percent: 40, source: "api")
    expect(e.stats_summary).to eq(eligible: 1700, turnout: 800, bad_ballots: 6, no_vote: 14)
  end

  it "reports the leading candidate per zone" do
    e = build_election(zones: 1, candidates: 2)
    zone = e.zones.first
    c1, c2 = e.candidates.order(:number).to_a
    VoteResult.create!(zone:, candidate: c1, votes: 10, source: "api")
    VoteResult.create!(zone:, candidate: c2, votes: 30, source: "api")
    expect(zone.leading_candidate).to eq(c2)
  end
end
