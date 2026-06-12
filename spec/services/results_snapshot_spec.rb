require "rails_helper"
require "aws-sdk-s3"

RSpec.describe ResultsSnapshot do
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
    expect(z1[:top]).to eq([{ number: 1, votes: 100 }, { number: 2, votes: 60 }])
    expect(snap[:zones].size).to eq(2)
    expect(snap[:zones].map { |z| z[:code] }).to eq(%w[01 02])
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
