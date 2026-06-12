class Election < ApplicationRecord
  has_many :candidates, dependent: :destroy
  has_many :zones, dependent: :destroy

  enum :data_mode, { api: "api", manual: "manual" }, default: "api"

  validates :name, :election_date, presence: true

  def self.current = order(created_at: :desc).first

  # ผู้สมัครทุกคน + total_votes (SUM สดจาก 50 เขต — ไม่เก็บซ้ำ ตาม spec §6)
  def leaderboard
    @leaderboard ||= candidates
      .left_joins(:vote_results)
      .select("candidates.*, COALESCE(SUM(vote_results.votes), 0) AS total_votes")
      .group("candidates.id")
      .order("total_votes DESC, candidates.number ASC")
      .to_a
  end

  def total_votes
    VoteResult.joins(:zone).where(zones: { election_id: id }).sum(:votes)
  end

  # เฉลี่ยทั้ง 50 เขต — เขตที่ยังไม่รายงานนับเป็น 0
  def counted_percent
    return 0.to_d if zones.none?
    (ZoneStat.where(zone: zones).sum(:counted_percent) / zones.count).round(1)
  end

  def stats_summary
    stats = ZoneStat.where(zone: zones)
    {
      eligible: stats.sum(:eligible_voters),
      turnout: stats.sum(:turnout),
      bad_ballots: stats.sum(:bad_ballots),
      no_vote: stats.sum(:no_vote)
    }
  end
end
