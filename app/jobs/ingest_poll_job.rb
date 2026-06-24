class IngestPollJob < ApplicationJob
  queue_as :default
  retry_on Ingest::Client::FetchError, wait: 5.seconds, attempts: 2

  SLUGS = { "governor" => nil, "council" => "bkk-council-2026" }.freeze

  def perform(kind = "governor")
    election = (kind == "council" ? Election.council : Election.governor)
    return if election.nil? || election.manual?

    if ENV["ECT_API_URL"].blank?
      Rails.logger.info("[ingest:#{kind}] ECT_API_URL not configured — skipping")
      return
    end

    candidate_map = election.candidates.where.not(external_id: nil).pluck(:external_id, :number).to_h
    if candidate_map.empty?
      Rails.logger.warn("[ingest:#{kind}] no candidates synced — skipping")
      return
    end

    raw = Ingest::Client.fetch_results(SLUGS.fetch(kind))
    src = raw["source"] || {}
    Rails.logger.info("[ingest:#{kind}] source=#{src['selected']} coverage=#{src['areasWithData']}/#{src['competitiveAreasTotal']}")

    parsed = Ingest::EctAdapter.parse(
      raw,
      expected_zone_codes: election.zones.pluck(:code),
      candidate_map: candidate_map
    )
    unless parsed.ok?
      Rails.logger.error("[ingest:#{kind}] rejected payload: #{parsed.errors.join('; ')}")
      return
    end

    changed = false
    election.zones.find_each do |zone|
      data = parsed.data[zone.code] or next
      begin
        changed |= ResultWriter.new(zone, source: "api").apply!(data[:votes], stats: data[:stats])
      rescue ResultWriter::StaleVotesError => e
        Rails.logger.error("[ingest:#{kind}] #{e.message} — zone skipped")
      end
    end

    if changed && kind == "governor"
      begin
        ResultsBroadcaster.new(election).broadcast_all
      rescue StandardError => e
        Rails.logger.error("[ingest:#{kind}] broadcast failed: #{e.class} #{e.message}")
      end
    end

    SnapshotPublisher.new(election).publish
    SnapshotArchiveJob.perform_later(election.id, Time.current.iso8601)
  end
end
