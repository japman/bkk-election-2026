require "rails_helper"

RSpec.describe IngestPollJob do
  let!(:election) { build_election(zones: 2, candidates: 2) }
  let(:raw) { Rails.root.join("spec/fixtures/ingest/valid.json").read }
  let(:raw_hash) { JSON.parse(raw) }
  let(:publisher) { instance_double(SnapshotPublisher, publish: true) }

  before do
    ENV["ECT_API_URL"] = "https://partner.example/results"
    ENV["ECT_API_TOKEN"] = "test-token"
    allow(Ingest::Client).to receive(:fetch_results).and_return(raw_hash)
    allow(SnapshotPublisher).to receive(:new).and_return(publisher)
    allow(ResultsBroadcaster).to receive(:new)
      .and_return(instance_double(ResultsBroadcaster, broadcast_all: true))
  end

  after { ENV.delete("ECT_API_URL"); ENV.delete("ECT_API_TOKEN") }

  it "writes results and stats from the API payload, then publishes snapshot" do
    described_class.perform_now
    expect(VoteResult.sum(:votes)).to eq(18230 + 15110 + 14020 + 16880)
    expect(election.zones.first.zone_stat.counted_percent).to eq(72.5)
    expect(publisher).to have_received(:publish)
  end

  it "publishes every successful poll so the fallback snapshot never goes stale" do
    described_class.perform_now
    described_class.perform_now
    expect(publisher).to have_received(:publish).twice
  end

  it "still publishes the snapshot when broadcasting fails" do
    allow(ResultsBroadcaster).to receive(:new)
      .and_return(instance_double(ResultsBroadcaster).tap { |b|
        allow(b).to receive(:broadcast_all).and_raise(RuntimeError, "cable down")
      })
    allow(Rails.logger).to receive(:error)
    described_class.perform_now
    expect(publisher).to have_received(:publish)
    expect(Rails.logger).to have_received(:error).with(/broadcast failed/)
  end

  it "skips quietly when ECT_API_URL is not configured" do
    ENV.delete("ECT_API_URL")
    described_class.perform_now
    expect(VoteResult.count).to eq(0)
    expect(publisher).not_to have_received(:publish)
  end

  it "skips entirely when election is in manual mode (admin override)" do
    election.update!(data_mode: "manual")
    described_class.perform_now
    expect(VoteResult.count).to eq(0)
  end

  it "rejects an invalid payload and writes nothing" do
    allow(Ingest::Client).to receive(:fetch_results).and_return({ "zones" => "เพี้ยน" })
    allow(Rails.logger).to receive(:error)
    described_class.perform_now
    expect(VoteResult.count).to eq(0)
    expect(Rails.logger).to have_received(:error).with(/rejected/)
  end

  it "enqueues SnapshotArchiveJob with the election id after a successful poll" do
    expect { described_class.perform_now }
      .to have_enqueued_job(SnapshotArchiveJob).with(election.id, anything)
  end

  it "skips a zone whose votes decreased but applies the rest" do
    described_class.perform_now
    lowered = JSON.parse(raw)
    lowered["zones"][0]["results"][0]["votes"] = 1        # เขต 01 ลดลง → ข้าม
    lowered["zones"][1]["results"][0]["votes"] = 20000     # เขต 02 เพิ่ม → ใช้
    allow(Ingest::Client).to receive(:fetch_results).and_return(lowered)
    allow(Rails.logger).to receive(:error)
    described_class.perform_now
    z1, z2 = election.zones.order(:code).to_a
    expect(z1.vote_results.joins(:candidate).find_by(candidates: { number: 1 }).votes).to eq(18230)
    expect(z2.vote_results.joins(:candidate).find_by(candidates: { number: 1 }).votes).to eq(20000)
  end
end
