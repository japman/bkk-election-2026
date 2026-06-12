class IngestPollJob < ApplicationJob
  queue_as :default

  # API ล่ม/timeout → exponential backoff (spec §7) — รอบถัดไปของ recurring จะมาใน 30 วิอยู่แล้ว
  retry_on Ingest::Client::FetchError, wait: :polynomially_longer, attempts: 5

  def perform
    election = Election.current
    return if election.nil? || election.manual?

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

    SnapshotPublisher.new(election).publish if changed
  end
end
