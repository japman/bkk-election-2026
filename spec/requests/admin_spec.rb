require "rails_helper"

RSpec.describe "Admin panel", type: :request do
  include ElectionSetup

  let!(:election) { build_election(zones: 1, candidates: 2) }
  let(:zone) { election.zones.first }
  let(:admin) { create_admin }

  it "redirects unauthenticated users to login" do
    get admin_root_path
    expect(response).to redirect_to(new_session_path)
  end

  describe "เมื่อ login แล้ว" do
    before { sign_in_as(admin) }

    it "shows the zone list" do
      get admin_root_path
      expect(response.body).to include("เขต 1")
    end

    it "requires the confirm checkbox before saving" do
      patch admin_zone_result_path(zone), params: { votes: { "1" => "999" } }
      expect(zone.vote_results.count).to eq(0)
      expect(flash[:alert]).to include("ยืนยัน")
    end

    it "saves manual results with revision attributed to the editor" do
      patch admin_zone_result_path(zone), params: {
        confirm: "1",
        votes: { "1" => "999", "2" => "500" },
        stats: { eligible_voters: "90000", turnout: "50000", bad_ballots: "100",
                 no_vote: "200", counted_percent: "55.5" }
      }
      expect(zone.vote_results.sum(:votes)).to eq(1499)
      expect(zone.reload.zone_stat.counted_percent).to eq(55.5)
      rev = ResultRevision.where(source: "admin").last
      expect(rev.editor).to eq(admin.email_address)
    end

    it "allows decreasing votes (admin override)" do
      ResultWriter.new(zone, source: "api").apply!({ 1 => 1000 })
      patch admin_zone_result_path(zone), params: { confirm: "1", votes: { "1" => "900" } }
      expect(zone.vote_results.first.reload.votes).to eq(900)
    end

    it "toggles data mode between api and manual" do
      expect {
        patch toggle_mode_admin_election_path
      }.to change { election.reload.data_mode }.from("api").to("manual")
    end
  end
end
