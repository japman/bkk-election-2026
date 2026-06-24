require "rails_helper"

RSpec.describe SnapshotArchiveJob do
  let!(:election) { build_election(zones: 1, candidates: 2) }
  let(:s3) { instance_double(Aws::S3::Client, put_object: nil) }

  before do
    require "aws-sdk-s3"
    allow(Aws::S3::Client).to receive(:new).and_return(s3)
  end

  context "when SNAPSHOT_BUCKET is set" do
    around do |example|
      old = ENV["SNAPSHOT_BUCKET"]
      ENV["SNAPSHOT_BUCKET"] = "test-bucket"
      example.run
      ENV["SNAPSHOT_BUCKET"] = old
    end

    it "uploads the snapshot JSON with the correct S3 key using Bangkok time (+07:00 input)" do
      expected_json = ResultsSnapshot.new(election).as_json.to_json
      allow(ResultsSnapshot).to receive(:new).with(election).and_call_original

      described_class.perform_now(election.id, "2026-06-24T15:30:45+07:00")

      expect(s3).to have_received(:put_object).once.with(
        bucket: "test-bucket",
        key: "snapshots/2026-06-24/153045.json",
        body: be_a(String),
        content_type: "application/json",
        cache_control: "max-age=31536000, immutable"
      )
    end

    it "derives Bangkok date from a UTC instant that falls on the next Bangkok day" do
      # "2026-06-24T18:30:00Z" = 2026-06-25T01:30:00+07:00 Bangkok
      described_class.perform_now(election.id, "2026-06-24T18:30:00Z")

      expect(s3).to have_received(:put_object).once.with(
        hash_including(key: "snapshots/2026-06-25/013000.json")
      )
    end

    it "sets content_type and cache_control headers exactly" do
      described_class.perform_now(election.id, "2026-06-24T15:30:45+07:00")

      expect(s3).to have_received(:put_object).once.with(
        hash_including(
          content_type: "application/json",
          cache_control: "max-age=31536000, immutable"
        )
      )
    end

    it "uses the ResultsSnapshot JSON as the body" do
      snapshot = ResultsSnapshot.new(election)
      allow(ResultsSnapshot).to receive(:new).with(election).and_return(snapshot)
      expected_json = snapshot.as_json.to_json

      described_class.perform_now(election.id, "2026-06-24T15:30:45+07:00")

      expect(s3).to have_received(:put_object).once.with(
        hash_including(body: expected_json)
      )
    end

    it "does NOT call put_object when the election id is unknown" do
      described_class.perform_now(999_999, "2026-06-24T15:30:45+07:00")

      expect(s3).not_to have_received(:put_object)
    end
  end

  context "when SNAPSHOT_BUCKET is blank" do
    around do |example|
      old = ENV["SNAPSHOT_BUCKET"]
      ENV.delete("SNAPSHOT_BUCKET")
      example.run
      ENV["SNAPSHOT_BUCKET"] = old if old
    end

    it "does NOT call put_object (archive is S3-only)" do
      described_class.perform_now(election.id, "2026-06-24T15:30:45+07:00")

      expect(s3).not_to have_received(:put_object)
    end
  end

  context "when SNAPSHOT_BUCKET is empty string" do
    around do |example|
      old = ENV["SNAPSHOT_BUCKET"]
      ENV["SNAPSHOT_BUCKET"] = ""
      example.run
      ENV["SNAPSHOT_BUCKET"] = old
    end

    it "does NOT call put_object" do
      described_class.perform_now(election.id, "2026-06-24T15:30:45+07:00")

      expect(s3).not_to have_received(:put_object)
    end
  end
end
