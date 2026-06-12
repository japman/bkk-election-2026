require "rss"
require "open-uri"

module News
  # ดึงข่าวจากเว็บหลัก dailynews.co.th — ไม่เก็บในระบบนี้ (spec §6)
  # พังเมื่อไหร่คืน [] — หน้าเว็บผลคะแนนห้ามล่มเพราะข่าว
  class Fetcher
    FEED_URL = ENV.fetch("NEWS_FEED_URL", "https://www.dailynews.co.th/feed/")
    Item = Struct.new(:title, :url, :published_at)

    def self.latest(limit: 3)
      Rails.cache.fetch("news/latest/#{limit}", expires_in: 5.minutes) do
        feed = RSS::Parser.parse(fetch_xml, false)
        feed.items.first(limit).map { |i| Item.new(i.title, i.link, i.pubDate) }
      end
    rescue StandardError => e
      Rails.logger.warn("[news] feed failed: #{e.class} #{e.message}")
      []
    end

    def self.fetch_xml
      URI.open(FEED_URL, read_timeout: 5, open_timeout: 5).read
    end
  end
end
