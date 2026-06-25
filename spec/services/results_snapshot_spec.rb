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

  it "governor snapshot includes a trend series; council has none" do
    g = Election.create!(name: "G", election_date: Date.new(2026, 6, 28), kind: "governor")
    g.candidates.create!(number: 1, name: "A", party: "ก", color: "#0E8A45")
    g.record_trend_point!
    g.record_trend_point!
    trend = ResultsSnapshot.new(g).as_json[:trend]
    expect(trend.size).to eq(2)
    expect(trend.first).to include(:t, :votes)

    c = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    expect(ResultsSnapshot.new(c).as_json).not_to have_key(:trend)
  end
end

RSpec.describe ResultsSnapshot, "council payload" do
  it "council seats merge independents and grey multi-colour parties" do
    e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    e.candidates.create!(number: 1, name: "A", party: "อิสระ", color: "#aa0000")
    e.candidates.create!(number: 2, name: "B", party: "อิสระ", color: "#00aa00")
    z1 = e.zones.create!(code: "01", name: "z1", grid_col: 1, grid_row: 1)
    z2 = e.zones.create!(code: "02", name: "z2", grid_col: 2, grid_row: 1)
    ResultWriter.new(z1, source: "api").apply!({ 1 => 10 })
    ResultWriter.new(z2, source: "api").apply!({ 2 => 10 })

    seats = ResultsSnapshot.new(e).as_json[:seats]
    ind = seats.find { |s| s[:party] == "อิสระ" }
    expect(ind[:seats]).to eq(2)
    expect(ind[:color]).to eq("#888888")
  end

  it "builds a council payload with per-district winners and seats-by-party" do
    e = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    z = e.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    win = e.candidates.create!(number: 1, name: "W", party: "P1", color: "#111", zone: z)
    lose = e.candidates.create!(number: 2, name: "L", party: "P2", color: "#222", zone: z)
    VoteResult.create!(zone: z, candidate: win, votes: 600)
    VoteResult.create!(zone: z, candidate: lose, votes: 400)
    ZoneStat.create!(zone: z, eligible_voters: 2000, turnout: 1000, bad_ballots: 0, no_vote: 0, counted_percent: 90.0)
    json = described_class.new(e).as_json
    d = json[:districts].first
    expect(d[:winner]).to include(number: 1, party: "P1", votes: 600)
    expect(json[:seats]).to include(hash_including(party: "P1", seats: 1))
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
