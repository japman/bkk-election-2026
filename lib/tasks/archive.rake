# สร้างหน้า static archive (governor=index.html, council=council.html) ลง tmp/archive
#   BASE_URL=<url>   (จำเป็น)  เช่น https://d2qyp6lcqlvau.cloudfront.net
#   LOCAL_ONLY=1     ข้าม upload S3 (เขียนแค่ tmp/archive — preview)
# default = เขียน tmp/archive + upload S3 (ต้องตั้ง SNAPSHOT_BUCKET)
namespace :archive do
  desc "Build static results archive (index.html + council.html) to tmp/archive; uploads unless LOCAL_ONLY=1"
  task build: :environment do
    base_url = ENV["BASE_URL"].to_s.strip
    abort("BASE_URL is required (e.g. BASE_URL=https://d2qyp6lcqlvau.cloudfront.net)") if base_url.empty?

    upload = ENV["LOCAL_ONLY"] != "1"
    result = ArchiveBuilder.new(base_url: base_url).build!(upload: upload)

    puts "Archive built → #{result[:out_dir]}"
    puts "  base_url: #{base_url}   upload: #{upload}"
    puts "HTML pages:"
    result[:html].each { |file, bytes| puts format("  %-14s %8d bytes", file, bytes) }
    puts "Image assets (#{result[:images].size}):"
    result[:images].each { |rel| puts "  assets/#{rel}" }

    if upload
      puts "Uploaded #{result[:uploaded_keys].size} S3 keys to bucket #{ENV['SNAPSHOT_BUCKET']}:"
      result[:uploaded_keys].each { |k| puts "  #{k}" }
    else
      puts "LOCAL_ONLY=1 → skipped S3 upload"
    end
  end
end
