require "rails_helper"

RSpec.describe News::Fetcher do
  before do
    Rails.cache.clear
    stub_request(:get, %r{www\.dailynews\.co\.th/news/\d+/?\z}).to_return(body: "<html></html>")
  end

  it "parses feed items" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    items = described_class.latest(limit: 2)
    expect(items.size).to eq(2)
    expect(items.first.title).to eq("ข่าวเลือกตั้ง 1")
    expect(items.first.url).to eq("https://www.dailynews.co.th/news/1/")
    expect(items.first.published_at).to be_a(ActiveSupport::TimeWithZone)
    expect(items.first.published_at.utc_offset).to eq(7 * 3600)
  end

  it "converts a GMT pubDate to Bangkok time (UTC+7) for display" do
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel>
        <item><title>t</title><link>https://www.dailynews.co.th/news/9/</link>
          <description>d</description>
          <pubDate>Sat, 28 Jun 2026 03:35:00 +0000</pubDate></item>
      </channel></rss>
    XML
    allow(described_class).to receive(:fetch_xml).and_return(xml)
    t = described_class.latest(limit: 1).first.published_at
    expect(t.utc_offset).to eq(7 * 3600)
    expect(t.strftime("%d/%m/%Y • %H:%M")).to eq("28/06/2026 • 10:35")
  end

  it "returns [] when the feed is unreachable" do
    allow(described_class).to receive(:fetch_xml).and_raise(SocketError)
    expect(described_class.latest).to eq([])
  end

  it "includes a plain-text excerpt from the description" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    item = described_class.latest(limit: 1).first
    expect(item.excerpt).to eq("สรุปผลคะแนนเขตเลือกตั้งล่าสุด พร้อมบรรยากาศการนับคะแนนทั่วกรุงเทพมหานคร")
  end

  it "extracts the og:image URL for each item (link only)" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    stub_request(:get, "https://www.dailynews.co.th/news/1/")
      .to_return(body: '<html><head><meta property="og:image" content="https://img.example/a.jpg" /></head></html>')
    stub_request(:get, "https://www.dailynews.co.th/news/2/")
      .to_return(body: '<html><head><meta property="og:image" content="https://img.example/b.jpg" /></head></html>')
    items = described_class.latest(limit: 2)
    expect(items.map(&:image_url)).to eq(["https://img.example/a.jpg", "https://img.example/b.jpg"])
  end

  it "extracts og:image regardless of attribute order (content before property)" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    stub_request(:get, "https://www.dailynews.co.th/news/1/")
      .to_return(body: '<html><head><meta content="https://img.example/c.jpg" property="og:image" /></head></html>')
    stub_request(:get, "https://www.dailynews.co.th/news/2/").to_return(body: "<html></html>")
    expect(described_class.latest(limit: 2).first.image_url).to eq("https://img.example/c.jpg")
  end

  it "leaves image_url nil when the article fetch fails (items still returned)" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    stub_request(:get, %r{www\.dailynews\.co\.th/news/\d+/?\z}).to_timeout
    items = described_class.latest(limit: 2)
    expect(items.size).to eq(2)
    expect(items.map(&:image_url)).to eq([nil, nil])
  end

  # HTTP body อ่านด้วย f.read(n) ได้ ASCII-8BIT — ถ้า og:image URL มี byte non-ASCII (path ไทย)
  # ต้อง force เป็น UTF-8 ไม่งั้น ERB (UTF-8) จะ raise Encoding::CompatibilityError → /news 500
  it "returns a valid UTF-8 image_url even when the page bytes are ASCII-8BIT (Thai in URL)" do
    binary_head = %(<html><head><meta property="og:image" content="https://img.example/ภาพข่าว.jpg"></head>).b
    reader = double("io", read: binary_head)
    allow(URI).to receive(:open) { |*_args, &blk| blk.call(reader) }

    result = described_class.og_image("https://www.dailynews.co.th/news/1/")

    expect(result).to eq("https://img.example/ภาพข่าว.jpg")
    expect(result.encoding.name).to eq("UTF-8")
    expect(result).to be_valid_encoding
  end
end
