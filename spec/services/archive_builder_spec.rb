require "rails_helper"
require "aws-sdk-s3"

RSpec.describe ArchiveBuilder do
  let(:base_url) { "https://d2qyp6lcqlvau.cloudfront.net" }
  let(:out_dir)  { Rails.root.join("tmp/archive_spec_#{SecureRandom.hex(4)}") }

  # โครงสร้างข้อมูลขั้นต่ำ: governor (ชัชชาติ ชนะ + 50 เขต) + council
  def seed_governor!
    g = Election.create!(name: "ผู้ว่าฯ", election_date: Date.new(2026, 6, 28), kind: "governor")
    win = g.candidates.create!(number: 1, name: "ชัชชาติ สิทธิพันธุ์", party: "อิสระ",
                               color: "#0E7A3D", photo_url: "/images/candidates/1.png",
                               party_logo_url: "/images/parties/x.png", total_votes: 1000)
    runner = g.candidates.create!(number: 2, name: "คู่แข่ง", party: "พรรคสอง",
                                  color: "#C42B2B", total_votes: 400)
    50.times do |i|
      z = g.zones.create!(code: format("%02d", i + 1), name: "เขต #{i + 1}",
                          grid_col: (i % 12) + 1, grid_row: (i / 12) + 1)
      ResultWriter.new(z, source: "api").apply!(
        { 1 => 100, 2 => 40 },
        stats: { eligible_voters: 500, turnout: 150, bad_ballots: 3, no_vote: 2, counted_percent: 90 }
      )
    end
    g.record_trend_point!
    g.record_trend_point!
    g
  end

  def seed_council!
    c = Election.create!(name: "สก", election_date: Date.new(2026, 6, 28), kind: "council")
    3.times do |i|
      z = c.zones.create!(code: format("%02d", i + 1), name: "เขต #{i + 1}",
                          grid_col: i + 1, grid_row: 1)
      w = c.candidates.create!(number: 1, name: "ผู้ชนะ #{i + 1}", party: "พรรค A",
                               color: "#1B6CC4", photo_url: "/images/council/0#{i + 1}/1.png", zone: z)
      l = c.candidates.create!(number: 2, name: "รอง #{i + 1}", party: "พรรค B", color: "#C42B2B", zone: z)
      VoteResult.create!(zone: z, candidate: w, votes: 600)
      VoteResult.create!(zone: z, candidate: l, votes: 300)
      ZoneStat.create!(zone: z, eligible_voters: 2000, turnout: 1000,
                       bad_ballots: 5, no_vote: 5, counted_percent: 85.0)
    end
    c
  end

  before do
    # ห้ามยิง network: stub feed ข่าว
    allow(News::Fetcher).to receive(:latest).and_return([])
    seed_governor!
    seed_council!
  end

  after { FileUtils.rm_rf(out_dir) }

  def build!(upload: false)
    described_class.new(base_url: base_url, out_dir: out_dir).build!(upload: upload)
  end

  def read(file) = File.read(out_dir.join(file))

  describe "#build! (local, no upload)" do
    it "writes index.html and council.html" do
      build!
      expect(File).to exist(out_dir.join("index.html"))
      expect(File).to exist(out_dir.join("council.html"))
    end

    it "renders the governor winner name and the embedded snapshot JSON" do
      build!
      html = read("index.html")
      expect(html).to include("ชัชชาติ สิทธิพันธุ์")

      m = html.match(%r{<script[^>]*id="snapshot"[^>]*>(.*?)</script>}m)
      expect(m).not_to be_nil
      data = JSON.parse(m[1])
      expect(data).to have_key("candidates")
      expect(data["candidates"].first["name"]).to eq("ชัชชาติ สิทธิพันธุ์")
    end

    it "includes all 50 zone tiles on the governor map" do
      build!
      html = read("index.html")
      expect(html.scan(/class="tile"/).size).to eq(50)
    end

    it "is self-contained — no importmap/turbo/stimulus/live tags or app http origin" do
      build!
      # ตัด inlined <style> ออกก่อน (CSS เดิมมี rule turbo-frame{} ซึ่งเป็น dead style ไม่ใช่ runtime)
      markup = read("index.html").sub(%r{<style>.*?</style>}m, "")
      expect(markup).not_to include("importmap")
      expect(markup).not_to include("turbo")          # ไม่มี turbo runtime/wiring ใน markup/script
      expect(markup).not_to include("stimulus")
      expect(markup).not_to include("data-turbo")
      expect(markup).not_to include("turbo_stream_from")
      expect(markup).not_to include("googletagmanager") # ไม่มี GA
      expect(markup).not_to include("cdn-consentrix")   # ไม่มี CMP script (credit link ยังคงไว้ได้)
    end

    it "rewrites every root-relative asset URL to a relative assets/ path" do
      build!
      %w[index.html council.html].each do |f|
        html = read(f)
        # ไม่มี asset URL ที่ขึ้นต้น "/" (เช่น "/images/.. หรือ "/assets/..)
        expect(html).not_to match(%r{["']/(?:images|assets)/})
      end
    end

    it "keeps the frozen absolute OG image URL (not rewritten to relative)" do
      build!
      html = read("index.html")
      expect(html).to include(%(content="#{base_url}/assets/og-cover.jpg"))
    end

    it "inlines application.css into a <style> block" do
      build!
      html = read("index.html")
      style = html[%r{<style>(.*?)</style>}m, 1]
      expect(style).not_to be_nil
      expect(style.length).to be > 5000
      expect(style).to include("--dn-pink")
      expect(style).to include(".tile")
    end

    it "embeds the council snapshot with districts + seats" do
      build!
      html = read("council.html")
      data = JSON.parse(html[%r{<script[^>]*id="snapshot"[^>]*>(.*?)</script>}m, 1])
      expect(data["kind"]).to eq("council")
      expect(data).to have_key("districts")
      expect(data).to have_key("seats")
      expect(html).to include("council-seats")
    end

    it "never references the request object in the rendered output" do
      build!
      expect(read("index.html")).not_to include("request.")
      expect(read("council.html")).not_to include("request.")
    end

    it "copies referenced + frozen image assets into out_dir/assets" do
      result = build!
      expect(File).to exist(out_dir.join("assets/logo-dn-pink-04.webp"))
      expect(File).to exist(out_dir.join("assets/og-cover.jpg"))
      expect(File).to exist(out_dir.join("assets/candidates/1.png"))
      expect(result[:images]).to include("candidates/1.png", "logo-dn-pink-04.webp", "og-cover.jpg")
    end
  end

  describe "#build!(upload: true)" do
    let(:s3) { instance_double(Aws::S3::Client) }

    around do |example|
      old = ENV["SNAPSHOT_BUCKET"]
      ENV["SNAPSHOT_BUCKET"] = "test-bucket"
      example.run
      old.nil? ? ENV.delete("SNAPSHOT_BUCKET") : ENV["SNAPSHOT_BUCKET"] = old
    end

    before do
      allow(Aws::S3::Client).to receive(:new).and_return(s3)
      allow(s3).to receive(:put_object)
    end

    it "uploads index.html and council.html with html content_type + short cache" do
      build!(upload: true)
      expect(s3).to have_received(:put_object).with(
        hash_including(bucket: "test-bucket", key: "index.html",
                       content_type: a_string_matching(%r{text/html}))
      )
      expect(s3).to have_received(:put_object).with(
        hash_including(bucket: "test-bucket", key: "council.html",
                       content_type: a_string_matching(%r{text/html}))
      )
    end

    it "uploads image assets under assets/ with correct content_type + long cache" do
      build!(upload: true)
      expect(s3).to have_received(:put_object).with(
        hash_including(key: "assets/logo-dn-pink-04.webp", content_type: "image/webp",
                       cache_control: a_string_matching(/immutable/))
      )
      expect(s3).to have_received(:put_object).with(
        hash_including(key: "assets/og-cover.jpg", content_type: "image/jpeg")
      )
    end

    it "returns the uploaded S3 keys" do
      result = build!(upload: true)
      expect(result[:uploaded_keys]).to include("index.html", "council.html", "assets/og-cover.jpg")
    end
  end
end
