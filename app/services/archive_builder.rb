# สร้างหน้า static HTML self-contained (governor=index.html, council=council.html)
# จากผล frozen → render + inline CSS + embed snapshot JSON + rewrite asset URL → assets/
# เก็บลง tmp/archive (preview) และ (opt-in) put ขึ้น S3 root + assets/ ผ่าน Aws::S3::Client
# ⚠️ ไม่มี request context — layout/view ห้ามใช้ request.* (ใช้ base_url ที่ส่งเข้ามา)
class ArchiveBuilder
  PAGES = [
    { template: "archive/governor", file: "index.html",   kind: :governor },
    { template: "archive/council",  file: "council.html", kind: :council }
  ].freeze

  # asset ตรึง (อ้างถึงด้วย path relative ตรงๆ ใน header/OG — ไม่ผ่าน rewrite) → ก็อปเสมอ
  FROZEN_ASSETS = {
    "logo-dn-pink-04.webp" => "app/assets/images/logo-dn-pink-04.webp",
    "og-cover.jpg"         => "public/og-cover.jpg",
    "icon.png"             => "public/icon.png"
  }.freeze

  # จับเฉพาะ asset URL ที่ "ขึ้นต้นด้วย /" หลังเครื่องหมายคำพูด/วงเล็บ
  # → จะไม่แตะ absolute URL อย่าง https://host/assets/og-cover.jpg (OG image)
  ASSET_RE = %r{(["'(])/(images|assets)/([^"')\s]+)}

  def initialize(base_url:, out_dir: "tmp/archive")
    @base_url = base_url.to_s.chomp("/")
    @out_dir  = Rails.root.join(out_dir)
    @assets   = {} # rel (ใต้ assets/) => source absolute Pathname
  end

  def build!(upload: false)
    register_frozen_assets
    rendered = {}
    PAGES.each do |page|
      election = page[:kind] == :council ? Election.council : Election.governor
      next if election.nil?

      rendered[page[:file]] = rewrite_assets(render_page(election, page[:template]))
    end

    write_files(rendered)
    keys = upload ? upload_to_s3(rendered) : []

    {
      out_dir: @out_dir.to_s,
      html: rendered.transform_values(&:bytesize),
      images: @assets.keys.sort,
      uploaded_keys: keys
    }
  end

  private

  def render_page(election, template)
    snapshot_json = ResultsSnapshot.new(election).as_json.to_json
    ApplicationController.render(
      template: template,
      layout: "archive",
      assigns: {
        election: election,
        snapshot_json: snapshot_json,
        base_url: @base_url,
        news_items: news_items,
        inline_css: inline_css
      }
    )
  end

  def inline_css
    @inline_css ||= Rails.root.join("app/assets/stylesheets/application.css").read
  end

  # ข่าว frozen ตอน build-time — feed ล่มคืน [] (News::Fetcher rescue ให้แล้ว) ไม่ทำ build พัง
  def news_items
    @news_items ||= News::Fetcher.latest(limit: 5)
  rescue StandardError
    []
  end

  def register_frozen_assets
    FROZEN_ASSETS.each { |rel, src| @assets[rel] = Rails.root.join(src) }
  end

  def rewrite_assets(html)
    html.gsub(ASSET_RE) do
      quote = Regexp.last_match(1)
      kind  = Regexp.last_match(2)
      path  = Regexp.last_match(3)
      register_asset(kind, path)
      "#{quote}assets/#{path}"
    end
  end

  def register_asset(kind, path)
    src = kind == "images" ? Rails.public_path.join("images", path) : Rails.public_path.join("assets", path)
    @assets[path] ||= src
  end

  def write_files(rendered)
    FileUtils.mkdir_p(@out_dir.join("assets"))
    rendered.each { |file, html| File.write(@out_dir.join(file), html) }
    @assets.each do |rel, src|
      next unless File.exist?(src)

      dest = @out_dir.join("assets", rel)
      FileUtils.mkdir_p(dest.dirname)
      FileUtils.cp(src, dest)
    end
  end

  def upload_to_s3(rendered)
    require "aws-sdk-s3"
    bucket = ENV.fetch("SNAPSHOT_BUCKET")
    client = Aws::S3::Client.new
    keys = []

    rendered.each do |file, html|
      client.put_object(
        bucket: bucket, key: file, body: html,
        content_type: "text/html; charset=utf-8",
        cache_control: "public, max-age=60"
      )
      keys << file
    end

    @assets.each do |rel, src|
      next unless File.exist?(src)

      key = "assets/#{rel}"
      client.put_object(
        bucket: bucket, key: key, body: File.binread(src),
        content_type: content_type_for(rel),
        cache_control: "public, max-age=31536000, immutable"
      )
      keys << key
    end

    keys
  end

  def content_type_for(path)
    case File.extname(path).downcase
    when ".png"          then "image/png"
    when ".jpg", ".jpeg" then "image/jpeg"
    when ".webp"         then "image/webp"
    when ".svg"          then "image/svg+xml"
    when ".gif"          then "image/gif"
    else "application/octet-stream"
    end
  end
end
