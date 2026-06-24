require "aws-sdk-s3"

class SnapshotArchiveJob < ApplicationJob
  queue_as :default
  retry_on Aws::Errors::ServiceError, wait: 5.seconds, attempts: 3

  ARCHIVE_TZ = "Asia/Bangkok"

  def perform(election_id, polled_at_iso)
    return if ENV["SNAPSHOT_BUCKET"].blank?            # archive is S3-only
    election = Election.find_by(id: election_id) or return

    json = ResultsSnapshot.new(election).as_json.to_json
    at  = Time.iso8601(polled_at_iso).in_time_zone(ARCHIVE_TZ)
    key = "snapshots/#{election.kind}/#{at.strftime('%Y-%m-%d')}/#{at.strftime('%H%M%S')}.json"

    Aws::S3::Client.new.put_object(
      bucket: ENV.fetch("SNAPSHOT_BUCKET"), key: key, body: json,
      content_type: "application/json", cache_control: "max-age=31536000, immutable"
    )
  end
end
