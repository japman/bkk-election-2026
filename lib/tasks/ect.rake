# lib/tasks/ect.rake
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
                      color: c.dig("party", "color") || "#888888", external_id: c["id"])
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
                    color: c.dig("party", "color") || "#888888", external_id: c["id"])
      end
      puts "[ect:sync_candidates] governor: #{candidates.size} candidates"
    end
  end
end
