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
end
