# เขียน results.json ทุกครั้งที่ข้อมูลเปลี่ยน (spec §5.4)
# production → S3 (CloudFront TTL 5 วิ ชี้มาที่ key นี้) | dev/test → public/results.json
class SnapshotPublisher
  KEY = "results.json"

  def initialize(election)
    @election = election
  end

  def publish
    json = ResultsSnapshot.new(@election).as_json.to_json
    if Rails.env.production?
      require "aws-sdk-s3"
      Aws::S3::Client.new.put_object(
        bucket: ENV.fetch("SNAPSHOT_BUCKET"), key: KEY, body: json,
        content_type: "application/json", cache_control: "max-age=5"
      )
    else
      File.write(Rails.public_path.join(KEY), json)
    end
  end
end
