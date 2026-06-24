# spec/jobs/ingest_poll_job_spec.rb  (key changes)
require "rails_helper"

RSpec.describe IngestPollJob do
  let!(:election) { build_election(zones: 50, candidates: 0) }
  let(:area_payload) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_area_results.json").read) }
  let(:candidates_fixture) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_candidates.json").read) }
  let(:publisher) { instance_double(SnapshotPublisher, publish: true) }

  before do
    ENV["ECT_API_URL"] = "https://media.election.in.th/api/media/elections/bkk-governor-2026"
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
end
