require "rails_helper"

RSpec.describe ResultWriter do
  let(:election) { build_election(zones: 1, candidates: 2) }
  let(:zone) { election.zones.first }

  it "creates results and revisions on first write" do
    changed = ResultWriter.new(zone, source: "api").apply!({ 1 => 100, 2 => 80 })
    expect(changed).to be true
    expect(zone.vote_results.sum(:votes)).to eq(180)
    expect(ResultRevision.count).to eq(2)
    expect(ResultRevision.first.source).to eq("api")
  end

  it "returns false when nothing changed" do
    ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })
    expect(ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })).to be false
    expect(ResultRevision.count).to eq(1)
  end

  it "rejects decreasing votes from api (spec §7)" do
    ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })
    expect {
      ResultWriter.new(zone, source: "api").apply!({ 1 => 90 })
    }.to raise_error(ResultWriter::StaleVotesError)
    expect(zone.vote_results.first.votes).to eq(100)
  end

  it "allows decreasing votes for confirmed admin edits" do
    ResultWriter.new(zone, source: "api").apply!({ 1 => 100 })
    ResultWriter.new(zone, source: "manual", editor: "ops@dailynews.co.th", allow_decrease: true)
      .apply!({ 1 => 90 })
    expect(zone.vote_results.first.reload.votes).to eq(90)
    rev = ResultRevision.order(:id).last
    expect(rev.source).to eq("admin")
    expect(rev.editor).to eq("ops@dailynews.co.th")
    expect(rev.old_values).to eq("votes" => 100)
  end

  it "updates zone stats with a revision" do
    ResultWriter.new(zone, source: "api")
      .apply!({}, stats: { eligible_voters: 900, turnout: 500, bad_ballots: 4, no_vote: 6, counted_percent: 55.5 })
    expect(zone.reload.zone_stat.turnout).to eq(500)
    expect(ResultRevision.last.recordable).to eq(zone.zone_stat)
  end

  it "stores numerically-typed values symmetrically in stat revisions" do
    ResultWriter.new(zone, source: "api")
      .apply!({}, stats: { eligible_voters: 900, turnout: 500, bad_ballots: 4, no_vote: 6, counted_percent: 55.5 })
    ResultWriter.new(zone, source: "api")
      .apply!({}, stats: { eligible_voters: 900, turnout: 500, bad_ballots: 4, no_vote: 6, counted_percent: 60.0 })
    rev = ResultRevision.order(:id).last.reload
    expect(rev.old_values["counted_percent"]).to eq(55.5)
    expect(rev.new_values["counted_percent"]).to eq(60.0)
  end

  it "writes votes to the zone-scoped candidate (council)" do
    e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    z1 = e.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "ข", grid_col: 2, grid_row: 1)
    e.candidates.create!(number: 1, name: "z1c1", color: "#111", zone: z1) # same number, inserted first
    c2 = e.candidates.create!(number: 1, name: "z2c1", color: "#222", zone: z2)
    ResultWriter.new(z2, source: "api").apply!({ 1 => 500 })
    expect(c2.vote_results.sum(:votes)).to eq(500)
  end
end
