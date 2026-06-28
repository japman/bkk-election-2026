require "rails_helper"

RSpec.describe IngestPollJob do
  let!(:election) { build_election(zones: 50, candidates: 0) }
  let(:area_payload) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_area_results.json").read) }
  let(:candidates_fixture) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_candidates.json").read) }
  let(:publisher) { instance_double(SnapshotPublisher, publish: true) }

  around do |ex|
    old_url = ENV["ECT_API_URL"]; old_tok = ENV["ECT_API_TOKEN"]
    ENV["ECT_API_URL"] = "https://media.election.in.th/api/media/elections/bkk-governor-2026"
    ex.run
    ENV["ECT_API_URL"] = old_url; ENV["ECT_API_TOKEN"] = old_tok
  end

  before do
    # seed the 18 real candidates with external_ids so candidate_map resolves
    candidates_fixture.dig("data", "candidates").each do |c|
      election.candidates.create!(number: c["number"], name: c["name"],
                                  party: c.dig("party", "name"), color: c.dig("party", "color"),
                                  external_id: c["id"])
    end
    allow(Ingest::Client).to receive(:fetch_results).and_return(area_payload)
    allow(Ingest::Client).to receive(:fetch_candidates).and_return(candidates_fixture)
    allow(SnapshotPublisher).to receive(:new).and_return(publisher)
    allow(ResultsBroadcaster).to receive(:new)
      .and_return(instance_double(ResultsBroadcaster, broadcast_all: true))
  end

  it "writes per-area results and stats from the real payload, then publishes" do
    described_class.perform_now
    expect(election.zones.find_by(code: "46").vote_results.find_by(candidate: election.candidates.find_by(number: 7)).votes).to eq(33913)
    expect(election.zones.find_by(code: "46").zone_stat.counted_percent).to eq(84.55)
    expect(publisher).to have_received(:publish)
  end

  it "enqueues SnapshotArchiveJob after a successful poll" do
    expect { described_class.perform_now }
      .to have_enqueued_job(SnapshotArchiveJob).with(election.id, anything)
  end

  it "skips the poll when no candidates are synced (empty map)" do
    election.candidates.update_all(external_id: nil)
    expect(Ingest::Client).not_to receive(:fetch_results)
    described_class.perform_now
  end

  it "skips when ECT_API_URL is not configured" do
    ENV["ECT_API_URL"] = ""
    expect(Ingest::Client).not_to receive(:fetch_results)
    described_class.perform_now
  end

  it "skips entirely when the election is in manual mode" do
    election.update!(data_mode: "manual")
    expect(Ingest::Client).not_to receive(:fetch_results)
    described_class.perform_now
  end

  it "still publishes the snapshot when broadcasting fails" do
    broadcaster = instance_double(ResultsBroadcaster)
    allow(ResultsBroadcaster).to receive(:new).and_return(broadcaster)
    allow(broadcaster).to receive(:broadcast_all).and_raise(StandardError, "broadcast boom")
    expect { described_class.perform_now }.not_to raise_error
    expect(publisher).to have_received(:publish)
  end

  it "rejects an invalid payload and writes nothing" do
    allow(Ingest::Client).to receive(:fetch_results).and_return({ "success" => false })
    expect { described_class.perform_now }.not_to raise_error
    expect(VoteResult.count).to eq(0)
  end

  it "ingests council results into per-zone candidates" do
    council = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    z = council.zones.create!(code: "40", name: "ก", grid_col: 1, grid_row: 1)
    c2 = council.candidates.create!(number: 2, name: "win", color: "#111", zone: z, external_id: "u2")
    ENV["ECT_API_URL"] = "https://media.election.in.th/api/media/elections/bkk-governor-2026"
    payload = { "success" => true, "data" => { "areas" => [
      { "area_number" => 40, "results" => [{ "candidate_id" => "u2", "votes" => 6000 }],
        "metadata" => { "total_eligible_voters" => 9000, "total_votes" => 6500, "invalid_votes" => 30,
                        "no_votes" => 10, "coverage_percentage" => 85.0 } }] }, "source" => { "selected" => "final" } }
    allow(Ingest::Client).to receive(:fetch_results).with("bkk-council-2026").and_return(payload)
    allow(SnapshotPublisher).to receive(:new).and_return(instance_double(SnapshotPublisher, publish: true))
    allow(ResultsBroadcaster).to receive(:new).and_return(instance_double(ResultsBroadcaster, broadcast_all: true))
    described_class.perform_now("council")
    expect(c2.vote_results.sum(:votes)).to eq(6000)
  end

  it "does NOT invoke ResultsBroadcaster when a council poll changes data" do
    council = Election.create!(name: "C2", election_date: Date.new(2026, 6, 28), kind: "council")
    z = council.zones.create!(code: "40", name: "ก", grid_col: 1, grid_row: 1)
    council.candidates.create!(number: 2, name: "win", color: "#111", zone: z, external_id: "u2")
    ENV["ECT_API_URL"] = "https://media.election.in.th/api/media/elections/bkk-governor-2026"
    payload = { "success" => true, "data" => { "areas" => [
      { "area_number" => 40, "results" => [{ "candidate_id" => "u2", "votes" => 7000 }],
        "metadata" => { "total_eligible_voters" => 9000, "total_votes" => 7200, "invalid_votes" => 20,
                        "no_votes" => 5, "coverage_percentage" => 90.0 } }] }, "source" => { "selected" => "final" } }
    allow(Ingest::Client).to receive(:fetch_results).with("bkk-council-2026").and_return(payload)
    allow(SnapshotPublisher).to receive(:new).and_return(instance_double(SnapshotPublisher, publish: true))
    broadcaster_double = instance_double(ResultsBroadcaster, broadcast_all: true)
    allow(ResultsBroadcaster).to receive(:new).and_return(broadcaster_double)

    described_class.perform_now("council")

    expect(broadcaster_double).not_to have_received(:broadcast_all)
  end

  it "still broadcasts when a governor poll changes data" do
    broadcaster_double = instance_double(ResultsBroadcaster, broadcast_all: true)
    allow(ResultsBroadcaster).to receive(:new).and_return(broadcaster_double)
    described_class.perform_now
    expect(broadcaster_double).to have_received(:broadcast_all)
  end

  it "records a trend point on a governor poll that changes results" do
    expect { described_class.perform_now }.to change { election.trend_points.count }.by(1)
  end

  it "stores each candidate's authoritative total from the candidates endpoint" do
    described_class.perform_now
    c7 = candidates_fixture.dig("data", "candidates").find { |c| c["number"] == 7 }
    expect(election.candidates.find_by(number: 7).total_votes).to eq(c7["totalVotes"])
  end

  it "stores the ECT coverage percentage on the election (real counting %)" do
    described_class.perform_now
    expect(election.reload.coverage_percent.to_f)
      .to eq(candidates_fixture.dig("data", "coverage", "percentage"))
    expect(election.counted_percent).to eq(85.1) # 85.06 rounded to 1 dp
  end

  it "follows the API downward on a later poll (allow_decrease for source api)" do
    cid = candidates_fixture.dig("data", "candidates").find { |c| c["number"] == 7 }["id"]
    area = lambda do |votes|
      { "success" => true, "data" => { "areas" => [
        { "area_number" => 46, "results" => [ { "candidate_id" => cid, "votes" => votes } ],
          "metadata" => { "total_eligible_voters" => 100, "total_votes" => votes,
                          "invalid_votes" => 0, "no_votes" => 0, "coverage_percentage" => 50.0 } } ] },
        "source" => { "selected" => "realtime" } }
    end
    allow(Ingest::Client).to receive(:fetch_results).and_return(area.call(500), area.call(300))
    cand7 = election.candidates.find_by(number: 7)

    described_class.perform_now
    expect(election.zones.find_by(code: "46").vote_results.find_by(candidate: cand7).votes).to eq(500)

    described_class.perform_now
    expect(election.zones.find_by(code: "46").vote_results.find_by(candidate: cand7).votes).to eq(300)
  end
end
