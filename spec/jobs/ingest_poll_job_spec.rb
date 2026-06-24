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
end
