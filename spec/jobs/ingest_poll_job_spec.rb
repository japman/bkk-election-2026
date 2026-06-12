require "rails_helper"

RSpec.describe IngestPollJob do
  let!(:election) { build_election(zones: 2, candidates: 2) }
  let(:raw) { Rails.root.join("spec/fixtures/ingest/valid.json").read }
  let(:publisher) { instance_double(SnapshotPublisher, publish: true) }

  before do
    allow(Ingest::Client).to receive(:fetch).and_return(raw)
    allow(SnapshotPublisher).to receive(:new).and_return(publisher)
  end

  it "writes results and stats from the API payload, then publishes snapshot" do
    described_class.perform_now
    expect(VoteResult.sum(:votes)).to eq(18230 + 15110 + 14020 + 16880)
    expect(election.zones.first.zone_stat.counted_percent).to eq(72.5)
    expect(publisher).to have_received(:publish)
  end

  it "does not publish when nothing changed" do
    described_class.perform_now
    described_class.perform_now
    expect(publisher).to have_received(:publish).once
  end

  it "skips entirely when election is in manual mode (admin override)" do
    election.update!(data_mode: "manual")
    described_class.perform_now
    expect(VoteResult.count).to eq(0)
  end

  it "rejects an invalid payload and writes nothing" do
    allow(Ingest::Client).to receive(:fetch).and_return({ zones: "เพี้ยน" }.to_json)
    allow(Rails.logger).to receive(:error)
    described_class.perform_now
    expect(VoteResult.count).to eq(0)
    expect(Rails.logger).to have_received(:error).with(/rejected/)
  end

  it "skips a zone whose votes decreased but applies the rest" do
    described_class.perform_now
    lowered = JSON.parse(raw)
    lowered["zones"][0]["results"][0]["votes"] = 1        # เขต 01 ลดลง → ข้าม
    lowered["zones"][1]["results"][0]["votes"] = 20000     # เขต 02 เพิ่ม → ใช้
    allow(Ingest::Client).to receive(:fetch).and_return(lowered.to_json)
    allow(Rails.logger).to receive(:error)
    described_class.perform_now
    z1, z2 = election.zones.order(:code).to_a
    expect(z1.vote_results.joins(:candidate).find_by(candidates: { number: 1 }).votes).to eq(18230)
    expect(z2.vote_results.joins(:candidate).find_by(candidates: { number: 1 }).votes).to eq(20000)
  end
end
