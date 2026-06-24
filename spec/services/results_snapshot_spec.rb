require "rails_helper"
require "aws-sdk-s3"

RSpec.describe ResultsSnapshot do
  it "includes photo_url and party_logo_url for each candidate" do
    e = build_election(zones: 1, candidates: 1)
    c = e.candidates.first
    c.update!(photo_url: "/images/candidates/1.png", party_logo_url: "/images/parties/x.png")
    entry = described_class.new(e).as_json[:candidates].first
    expect(entry).to include(photo_url: "/images/candidates/1.png", party_logo_url: "/images/parties/x.png")
  end

  it "builds the public payload" do
    e = build_election(zones: 2, candidates: 2)
    ResultWriter.new(e.zones.first, source: "api").apply!(
      { 1 => 100, 2 => 60 },
      stats: { eligible_voters: 500, turnout: 170, bad_ballots: 5, no_vote: 5, counted_percent: 50 }
    )

    snap = ResultsSnapshot.new(e).as_json
    expect(snap[:counted_percent]).to eq(25.0)
    expect(snap[:stats][:turnout]).to eq(170)

    top = snap[:candidates].first
    expect(top[:number]).to eq(1)
    expect(top[:votes]).to eq(100)
    expect(top[:percent]).to eq(62.5)

    z1 = snap[:zones].find { |z| z[:code] == "01" }
    expect(z1[:leader_number]).to eq(1)
    expect(z1[:results]).to eq([ { number: 1, votes: 100 }, { number: 2, votes: 60 } ])
    expect(snap[:zones].size).to eq(2)
    expect(snap[:zones].map { |z| z[:code] }).to eq(%w[01 02])
  end

  it "includes full per-zone results (all candidates) and zone stats" do
    e = build_election(zones: 1, candidates: 4)
    zone = e.zones.first
    e.candidates.order(:number).each_with_index do |c, i|
      VoteResult.create!(zone: zone, candidate: c, votes: (i + 1) * 100)
    end
    ZoneStat.create!(zone: zone, eligible_voters: 5000, turnout: 3000,
                     bad_ballots: 40, no_vote: 20, counted_percent: 80.0)
    z = described_class.new(e).as_json[:zones].first
    expect(z[:results].size).to eq(4)                       # all candidates, not capped at 3
    expect(z[:results].map { |r| r[:votes] }).to eq([400, 300, 200, 100]) # desc
    expect(z[:stats]).to eq(eligible_voters: 5000, turnout: 3000, bad_ballots: 40, no_vote: 20)
    expect(z).not_to have_key(:top)
  end

  it "renders zone stats as 0 when the zone has no zone_stat" do
    e = build_election(zones: 1, candidates: 1)
    z = described_class.new(e).as_json[:zones].first
    expect(z[:stats]).to eq(eligible_voters: 0, turnout: 0, bad_ballots: 0, no_vote: 0)
  end
end

RSpec.describe SnapshotPublisher do
  it "writes results.json to public/ when SNAPSHOT_BUCKET is not set" do
    e = build_election(zones: 1, candidates: 1)
    path = Rails.public_path.join("results.json")
    FileUtils.rm_f(path)
    ENV.delete("SNAPSHOT_BUCKET")

    SnapshotPublisher.new(e).publish

    expect(JSON.parse(path.read)).to have_key("candidates")
  ensure
    FileUtils.rm_f(path)
    ENV.delete("SNAPSHOT_BUCKET")
  end

  it "puts results.json to S3 when SNAPSHOT_BUCKET is set" do
    e = build_election(zones: 1, candidates: 1)
    s3 = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(s3)
    expect(s3).to receive(:put_object).with(
      hash_including(bucket: "test-bucket", key: "results.json",
                     content_type: "application/json", cache_control: "max-age=5")
    )
    ENV["SNAPSHOT_BUCKET"] = "test-bucket"
    SnapshotPublisher.new(e).publish
  ensure
    ENV.delete("SNAPSHOT_BUCKET")
  end
end
