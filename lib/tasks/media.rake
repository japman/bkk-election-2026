require "fileutils"

module MediaSync
  GOV_FOLDER  = ENV.fetch("DRIVE_GOV_FOLDER",  "1wFbkHhM2YotcEmY045yLVN9JteMlFvpJ")
  LOGO_FOLDER = ENV.fetch("DRIVE_LOGO_FOLDER", "1Z01qgR20v2maDupmwWrgsECJN5UbOIgD")
  IMAGE_EXT   = /\.(png|jpe?g|webp)\z/i

  module_function

  def normalize(str)
    str.to_s.unicode_normalize(:nfc).gsub(/\s+/, "").downcase
  end

  def slug(stem)
    stem.strip.gsub(/\s+/, "-").downcase
  end

  def store(bytes, subdir, stem, ext)
    dir = Rails.public_path.join("images", subdir)
    FileUtils.mkdir_p(dir)
    File.binwrite(dir.join("#{stem}#{ext}"), bytes)
    "/images/#{subdir}/#{stem}#{ext}"
  end
end

namespace :media do
  desc "Import governor candidate photos + party logos from the public Drive folder into public/images"
  task sync_candidate_images: :environment do
    election = Election.current or abort("No current election")

    # --- photos: BKK-0NN.<ext> -> candidate number N ---
    photos = 0
    Drive::FolderClient.list(MediaSync::GOV_FOLDER).each do |f|
      m = f[:name].match(/\ABKK-(\d{3})(\.[A-Za-z]+)\z/i) or next
      number = m[1].to_i
      candidate = election.candidates.find_by(number: number) or next
      begin
        url = MediaSync.store(Drive::FolderClient.download(f[:id]), "candidates", number.to_s, m[2].downcase)
        candidate.update!(photo_url: url)
        photos += 1
      rescue Drive::FolderClient::Error => e
        Rails.logger.error("[media] photo #{f[:name]} failed: #{e.message}")
      end
    end

    # --- logos: filename stem ~= party name ---
    logo_map = {} # normalized stem => url
    Drive::FolderClient.list(MediaSync::LOGO_FOLDER).each do |f|
      next if f[:name].start_with?(".") || f[:name] == "Thumbs.db"
      ext = f[:name][MediaSync::IMAGE_EXT] or next
      stem = File.basename(f[:name], ext)
      begin
        url = MediaSync.store(Drive::FolderClient.download(f[:id]), "parties", MediaSync.slug(stem), ext.downcase)
        logo_map[MediaSync.normalize(stem)] = url
      rescue Drive::FolderClient::Error => e
        Rails.logger.error("[media] logo #{f[:name]} failed: #{e.message}")
      end
    end

    matched = 0
    election.candidates.find_each do |c|
      np = MediaSync.normalize(c.party)
      key = logo_map.keys.find { |k| !np.empty? && (k.include?(np) || np.include?(k)) }
      if key
        c.update!(party_logo_url: logo_map[key]); matched += 1
      else
        Rails.logger.info("[media] no logo for party=#{c.party.inspect} (##{c.number})")
      end
    end

    puts "[media] #{photos} photos, #{logo_map.size} logos, #{matched} candidates matched to a logo"
  end
end
