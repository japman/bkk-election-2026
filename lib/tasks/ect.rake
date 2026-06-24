# lib/tasks/ect.rake
namespace :ect do
  desc "Sync candidates (number/name/party/color/external_id) from the ECT API into Election.current"
  task sync_candidates: :environment do
    election = Election.current or abort("No current election")
    candidates = Ingest::Client.fetch_candidates.dig("data", "candidates") || []
    candidates.each do |c|
      record = election.candidates.find_or_initialize_by(number: c["number"])
      record.update!(
        name: c["name"],
        party: c.dig("party", "name"),
        color: c.dig("party", "color"),
        external_id: c["id"]
      )
    end
    message = "[ect:sync_candidates] upserted #{candidates.size} candidates"
    Rails.logger.info(message)
    puts message
  end
end
