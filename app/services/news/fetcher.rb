require "rss"
require "open-uri"

module News
  # ดึงข่าวเลือกตั้ง กทม. จากหมวด WordPress ของ dailynews.co.th
  # พังเมื่อไหร่คืน [] — หน้าเว็บผลคะแนนห้ามล่มเพราะข่าว
  class Fetcher
    FEED_URL = ENV.fetch("NEWS_FEED_URL", "https://www.dailynews.co.th/news/special/election-bangkok-69/feed/")
    Item = Struct.new(:title, :url, :published_at, :excerpt, :image_url)

    def self.latest(limit: 5)
      Rails.cache.fetch("news/latest/#{limit}", expires_in: 5.minutes) do
        feed = RSS::Parser.parse(fetch_xml, false)
        items = feed.items.first(limit).map do |i|
          Item.new(i.title, i.link, i.pubDate,
                   ActionController::Base.helpers.strip_tags(i.description.to_s).squish.truncate(140), nil)
        end
        images = items.map { |it| Thread.new { og_image(it.url) } }.map(&:value)
        items.each_with_index { |it, idx| it.image_url = images[idx] }
        items
      end
    rescue StandardError => e
      Rails.logger.warn("[news] feed failed: #{e.class} #{e.message}")
      []
    end

    def self.fetch_xml
      URI.open(FEED_URL, read_timeout: 5, open_timeout: 5).read
    end

    # ดึงเฉพาะ URL ของ og:image — อ่าน ~40KB แรกของ <head> เท่านั้น (ไม่โหลดไฟล์รูป)
    def self.og_image(url)
      head = URI.open(url, read_timeout: 4, open_timeout: 4) { |f| f.read(40_000) }
      head&.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i)&.captures&.first
    rescue StandardError
      nil
    end
  end
end
