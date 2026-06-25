require "rss"
require "open-uri"

module News
  # ดึงข่าวเลือกตั้ง กทม. จากหมวด WordPress ของ dailynews.co.th
  # พังเมื่อไหร่คืน [] — หน้าเว็บผลคะแนนห้ามล่มเพราะข่าว
  class Fetcher
    FEED_URL = ENV.fetch("NEWS_FEED_URL", "https://www.dailynews.co.th/news/special/election-bangkok-69/feed/")
    Item = Struct.new(:title, :url, :published_at, :excerpt)

    def self.latest(limit: 5)
      Rails.cache.fetch("news/latest/#{limit}", expires_in: 5.minutes) do
        feed = RSS::Parser.parse(fetch_xml, false)
        feed.items.first(limit).map do |i|
          Item.new(i.title, i.link, i.pubDate,
                   ActionController::Base.helpers.strip_tags(i.description.to_s).squish.truncate(140))
        end
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
