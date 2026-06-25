require "rails_helper"

RSpec.describe News::Fetcher do
  before { Rails.cache.clear }

  it "parses feed items" do
    allow(described_class).to receive(:fetch_xml)
      .and_return(Rails.root.join("spec/fixtures/news/feed.xml").read)
    items = described_class.latest(limit: 2)
    expect(items.size).to eq(2)
    expect(items.first.title).to eq("ข่าวเลือกตั้ง 1")
    expect(items.first.url).to eq("https://www.dailynews.co.th/news/1/")
    expect(items.first.published_at).to be_a(Time)
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
end
