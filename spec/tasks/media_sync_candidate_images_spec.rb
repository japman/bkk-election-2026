require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe "media:sync_candidate_images", type: :task do
  let!(:election) { build_election(zones: 0, candidates: 0) }
  let(:png) { "\x89PNG\r\n\x1a\nfake".b }
  let(:tmp_public) { Pathname(Dir.mktmpdir) }

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "media:sync_candidate_images" }
  end
  before do
    # Isolate file writes to a temp public dir so the spec never touches (or deletes) committed images.
    allow(Rails).to receive(:public_path).and_return(tmp_public)
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
    FileUtils.remove_entry(tmp_public) if tmp_public.exist?
  end

  it "downloads the BKK photo, writes it, and sets photo_url for number 7" do
    Rake::Task["media:sync_candidate_images"].invoke
    c7 = election.candidates.find_by(number: 7)
    expect(c7.photo_url).to eq("/images/candidates/7.png")
    expect(tmp_public.join("images/candidates/7.png").exist?).to be true
  end

  it "matches the party logo and sets party_logo_url, skipping junk files" do
    Rake::Task["media:sync_candidate_images"].invoke
    expect(election.candidates.find_by(number: 7).party_logo_url).to eq("/images/parties/ประชาชน.png")
    # independent party has no logo file → stays nil
    expect(election.candidates.find_by(number: 8).party_logo_url).to be_nil
    # junk skipped: no Thumbs.db / .DS_Store written
    expect(Dir[tmp_public.join("images/parties/*")].map { |f| File.basename(f) })
      .not_to include(".DS_Store", "Thumbs.db")
  end

  describe "council mode" do
    let(:tmp_public) { Pathname(Dir.mktmpdir) }

    after { FileUtils.remove_entry(tmp_public) if tmp_public.exist? }

    it "imports council photos into per-zone subfolders" do
      council = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
      z = council.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
      c = council.candidates.create!(number: 3, name: "x", color: "#111", zone: z)
      allow(Rails).to receive(:public_path).and_return(tmp_public)
      allow(Drive::FolderClient).to receive(:list).with(MediaSync::COUNCIL_FOLDER)
        .and_return([{ id: "p", name: "BKK-01-03.png" }, { id: "x", name: ".DS_Store" }])
      allow(Drive::FolderClient).to receive(:download).and_return(png)
      Rake::Task["media:sync_candidate_images"].reenable
      Rake::Task["media:sync_candidate_images"].invoke("council")
      expect(c.reload.photo_url).to eq("/images/council/01/3.png")
      expect(tmp_public.join("images/council/01/3.png").exist?).to be true
    end
  end
end
