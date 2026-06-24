class IngestPollJob < ApplicationJob
  queue_as :default
  retry_on Ingest::Client::FetchError, wait: 5.seconds, attempts: 2

  def perform
    election = Election.current
    return if election.nil? || election.manual?

    if ENV["ECT_API_URL"].blank?
      Rails.logger.info("[ingest] ECT_API_URL not configured — skipping poll")
      return
    end

    candidate_map = election.candidates.where.not(external_id: nil).pluck(:external_id, :number).to_h
    if candidate_map.empty?
      Rails.logger.warn("[ingest] no candidates synced (run rake ect:sync_candidates) — skipping poll")
      return
    end

    raw = Ingest::Client.fetch_results
    src = raw["source"] || {}
    Rails.logger.info("[ingest] source=#{src['selected']} coverage=#{src['areasWithData']}/#{src['competitiveAreasTotal']}")

    parsed = Ingest::EctAdapter.parse(
      raw,
      expected_zone_codes: election.zones.pluck(:code),
      candidate_map: candidate_map
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

    SnapshotPublisher.new(election).publish
    SnapshotArchiveJob.perform_later(election.id, Time.current.iso8601)
  end
end
