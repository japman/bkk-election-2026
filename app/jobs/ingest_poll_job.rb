class IngestPollJob < ApplicationJob
  queue_as :default

  # API ล่ม → ลองซ้ำเร็วๆ ครั้งเดียวพอ (รอบ recurring ถัดไปมาใน 30 วิอยู่แล้ว
  # backoff ยาวจะซ้อนกับ tick ใหม่เป็น concurrent ingest)
  retry_on Ingest::Client::FetchError, wait: 5.seconds, attempts: 2

  def perform
    election = Election.current
    return if election.nil? || election.manual?

    if ENV["ECT_API_URL"].blank?
      Rails.logger.info("[ingest] ECT_API_URL not configured — skipping poll")
      return
    end

    parsed = Ingest::EctAdapter.parse(
      Ingest::Client.fetch,
      expected_zone_codes: election.zones.pluck(:code),
      known_numbers: election.candidates.pluck(:number)
    )
    unless parsed.ok?
      Rails.logger.error("[ingest] rejected payload: #{parsed.errors.join('; ')}")
      return
    end

    changed = false
    election.zones.find_each do |zone|
      payload = parsed.data[zone.code] or next
      begin
        changed |= ResultWriter.new(zone, source: "api").apply!(payload[:votes], stats: payload[:stats])
      rescue ResultWriter::StaleVotesError => e
        Rails.logger.error("[ingest] #{e.message} — zone skipped")
      end
    end

    if changed
      begin
        ResultsBroadcaster.new(election).broadcast_all
      rescue StandardError => e
        Rails.logger.error("[ingest] broadcast failed: #{e.class} #{e.message}")
      end
    end
    # publish ทุกรอบที่ payload ผ่าน validation — กัน snapshot ค้างถาวรเมื่อ
    # publish รอบก่อนพังหลัง write commit แล้ว (ราคา S3 PUT ทุก 30 วิ = จิ๊บจ๊อย)
    SnapshotPublisher.new(election).publish
  end
end
