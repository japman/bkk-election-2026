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
    if parsed.warnings&.any?
      Rails.logger.info("[ingest:#{kind}] partial: #{parsed.warnings.size} note(s); #{parsed.warnings.first(3).join(' | ')}")
    end

    changed = false
    election.zones.find_each do |zone|
      data = parsed.data[zone.code] or next
      begin
        # source api: ตามค่าล่าสุดของ ECT ตรงๆ (allow_decrease) — feed realtime แกว่งขึ้นลงได้
        changed |= ResultWriter.new(zone, source: "api", allow_decrease: true).apply!(data[:votes], stats: data[:stats])
      rescue ResultWriter::StaleVotesError => e
        Rails.logger.error("[ingest:#{kind}] #{e.message} — zone skipped")
      end
    end

    # ยอดรวมรายคน (ภาพรวม) — ใช้ totalVotes ที่ ECT คำนวณให้ตรงจาก candidates endpoint
    # กัน drift จากการ SUM 50 เขตเอง (anti-rollback/เขตขาด)
    by_ext = election.candidates.where.not(external_id: nil).index_by(&:external_id)
    fetch_candidate_totals(SLUGS.fetch(kind)).each do |external_id, total|
      cand = by_ext[external_id]
      next if cand.nil? || cand.total_votes == total
      cand.update_column(:total_votes, total)
      changed = true
    end

    if changed && kind == "governor"
      begin
        election.record_trend_point!
        ResultsBroadcaster.new(election).broadcast_all
      rescue StandardError => e
        Rails.logger.error("[ingest:#{kind}] broadcast failed: #{e.class} #{e.message}")
      end
    end

    SnapshotPublisher.new(election).publish
    SnapshotArchiveJob.perform_later(election.id, Time.current.iso8601)
  end

  private

  # external_id => totalVotes จาก ECT candidates endpoint (วน pagination, ทนต่อ fetch ล้ม)
  def fetch_candidate_totals(slug)
    totals = {}
    page = 1
    loop do
      data = Ingest::Client.fetch_candidates(slug, page: page)["data"] || {}
      (data["candidates"] || []).each { |c| totals[c["id"]] = c["totalVotes"].to_i if c["id"] }
      break unless data.dig("pagination", "hasMore")
      page += 1
      break if page > 10
    end
    totals
  rescue Ingest::Client::FetchError => e
    Rails.logger.error("[ingest] candidate totals fetch failed: #{e.message}")
    {}
  end
end
