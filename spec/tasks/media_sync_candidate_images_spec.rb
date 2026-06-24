# spec/tasks/media_sync_candidate_images_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "media:sync_candidate_images", type: :task do
  let!(:election) { build_election(zones: 0, candidates: 0) }
  let(:png) { "\x89PNG\r\n\x1a\nfake".b }

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "media:sync_candidate_images" }
  end
  before do
    election.candidates.create!(number: 7, name: "ก", color: "#111", party: "ประชาชน")
    election.candidates.create!(number: 8, name: "ข", color: "#222", party: "อิสระ")
    allow(Drive::FolderClient).to receive(:list).with(MediaSync::GOV_FOLDER)
      .and_return([{ id: "g7", name: "BKK-007.png" }, { id: "x", name: ".DS_Store" }])
    allow(Drive::FolderClient).to receive(:list).with(MediaSync::LOGO_FOLDER)
      .and_return([{ id: "l1", name: "ประชาชน.png" }, { id: "t", name: "Thumbs.db" }])
    allow(Drive::FolderClient).to receive(:download).and_return(png)
  end
  after do
    Rake::Task["media:sync_candidate_images"].reenable
    FileUtils.rm_f(Dir[Rails.public_path.join("images/candidates/7.*")])
    FileUtils.rm_f(Dir[Rails.public_path.join("images/parties/*.*")])
  end

  it "downloads the BKK photo, writes it, and sets photo_url for number 7" do
    Rake::Task["media:sync_candidate_images"].invoke
    c7 = election.candidates.find_by(number: 7)
    expect(c7.photo_url).to eq("/images/candidates/7.png")
    expect(File.exist?(Rails.public_path.join("images/candidates/7.png"))).to be true
  end

  it "matches the party logo and sets party_logo_url, skipping junk files" do
    Rake::Task["media:sync_candidate_images"].invoke
    expect(election.candidates.find_by(number: 7).party_logo_url).to eq("/images/parties/ประชาชน.png")
    # independent party has no logo file → stays nil
    expect(election.candidates.find_by(number: 8).party_logo_url).to be_nil
    # junk skipped: no Thumbs.db / .DS_Store written
    expect(Dir[Rails.public_path.join("images/parties/*")].map { |f| File.basename(f) })
      .not_to include(".DS_Store", "Thumbs.db")
  end
end
