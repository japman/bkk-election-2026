# spec/tasks/ect_sync_candidates_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "ect:sync_candidates", type: :task do
  let!(:election) { build_election(zones: 0, candidates: 0) }
  let(:cands) { JSON.parse(Rails.root.join("spec/fixtures/ingest/ect_candidates.json").read) }

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "ect:sync_candidates" }
  end
  before { allow(Ingest::Client).to receive(:fetch_candidates).and_return(cands) }
  after  { Rake::Task["ect:sync_candidates"].reenable }

  it "upserts 18 candidates with external_id, party, and color" do
    Rake::Task["ect:sync_candidates"].invoke
    expect(election.candidates.count).to eq(18)
    c7 = election.candidates.find_by(number: 7)
    expect(c7.external_id).to eq("4ca853a4-c99e-39d9-a519-b5697be547f8")
    expect(c7.party).to eq("อิสระ")
    expect(c7.color).to eq("#888888")
  end

  it "is idempotent on re-run" do
    Rake::Task["ect:sync_candidates"].invoke
    Rake::Task["ect:sync_candidates"].reenable
    Rake::Task["ect:sync_candidates"].invoke
    expect(election.candidates.count).to eq(18)
  end

  it "syncs council candidates per zone across pages" do
    council = Election.create!(name: "C", election_date: Date.new(2026, 6, 28), kind: "council")
    council.zones.create!(code: "01", name: "ก", grid_col: 1, grid_row: 1)
    council.zones.create!(code: "02", name: "ข", grid_col: 2, grid_row: 1)
    page1 = { success: true, data: { candidates: [
      { id: "u1", number: 1, areaNumber: 1, name: "A", party: { name: "P1", color: "#111" } }],
      pagination: { hasMore: true } } }
    page2 = { success: true, data: { candidates: [
      { id: "u2", number: 1, areaNumber: 2, name: "B", party: { name: "P2", color: "#222" } }],
      pagination: { hasMore: false } } }
    allow(Ingest::Client).to receive(:fetch_candidates).with("bkk-council-2026", page: 1).and_return(JSON.parse(page1.to_json))
    allow(Ingest::Client).to receive(:fetch_candidates).with("bkk-council-2026", page: 2).and_return(JSON.parse(page2.to_json))
    Rake::Task["ect:sync_candidates"].reenable
    Rake::Task["ect:sync_candidates"].invoke("council")
    z1c1 = council.zones.find_by(code: "01").then { |z| council.candidates.find_by(zone: z, number: 1) }
    expect(z1c1.external_id).to eq("u1")
    expect(council.candidates.where(number: 1).count).to eq(2) # one per zone
  end
end
