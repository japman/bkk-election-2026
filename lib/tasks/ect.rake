# lib/tasks/ect.rake
module EctSync
  # The ECT API returns grey (#888888) for independents (most candidates), which
  # makes the leader map/leaderboard unreadable. Keep a real party color; otherwise
  # assign a distinct palette color by ballot number.
  PALETTE = %w[#0E8A45 #C42B2B #F47B20 #1E6FD6 #8B3FBF #E0317F #0CA678 #D9A406
               #5C7CFA #E8590C #2F9E44 #C2255C #1098AD #7048E8 #F08C00 #099268
               #862E9C #4263EB].freeze
  module_function

  def color(number, party_color)
    pc = party_color.to_s.downcase
    if pc.match?(/\A#[0-9a-f]{6}\z/) && pc != "#888888"
      party_color
    else
      PALETTE[(number.to_i - 1) % PALETTE.size]
    end
  end
end

namespace :ect do
  desc "Sync candidates from the ECT API (kind: governor|council)"
  task :sync_candidates, [ :kind ] => :environment do |_t, args|
    kind = args[:kind] || "governor"
    if kind == "council"
      election = Election.council or abort("No council election")
      slug = "bkk-council-2026"
      page = 1; total = 0
      loop do
        payload = Ingest::Client.fetch_candidates(slug, page: page)
        (payload.dig("data", "candidates") || []).each do |c|
          zone = election.zones.find_by(code: format("%02d", c["areaNumber"])) or next
          rec = election.candidates.find_or_initialize_by(zone: zone, number: c["number"])
          rec.update!(name: c["name"], party: c.dig("party", "name"),
                      color: EctSync.color(c["number"], c.dig("party", "color")), external_id: c["id"])
          total += 1
        end
        break unless payload.dig("data", "pagination", "hasMore")
        page += 1
      end
      puts "[ect:sync_candidates] council: #{total} candidates across #{page} page(s)"
    else
      election = Election.governor or abort("No governor election")
      candidates = Ingest::Client.fetch_candidates.dig("data", "candidates") || []
      candidates.each do |c|
        rec = election.candidates.find_or_initialize_by(number: c["number"])
        rec.update!(name: c["name"], party: c.dig("party", "name"),
                    color: EctSync.color(c["number"], c.dig("party", "color")), external_id: c["id"])
      end
      puts "[ect:sync_candidates] governor: #{candidates.size} candidates"
    end
  end
end
