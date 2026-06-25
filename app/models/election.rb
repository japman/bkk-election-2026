class Election < ApplicationRecord
  has_many :candidates, dependent: :destroy
  has_many :zones, dependent: :destroy
  has_many :trend_points, dependent: :destroy

  enum :data_mode, { api: "api", manual: "manual" }, default: "api"

  validates :name, :election_date, presence: true

  scope :governor_elections, -> { where(kind: "governor").order(created_at: :desc) }
  scope :council_elections,  -> { where(kind: "council").order(created_at: :desc) }
  def self.governor = governor_elections.first
  def self.council = council_elections.first
  def self.current = governor

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

  # สรุปที่นั่ง สก: รวมตามชื่อพรรค (อิสระหลายเบอร์รวมก้อนเดียว), สีเทาเมื่อหลายสี
  KEEP_TREND_POINTS = 300

  # บันทึกคะแนนรวมของผู้สมัครทุกคน ณ ขณะนี้เป็น 1 จุดในกราฟเทรนด์ (governor)
  def record_trend_point!
    votes = leaderboard.to_h { |c| [c.number.to_s, c.total_votes.to_i] }
    point = trend_points.create!(captured_at: Time.current, votes: votes)
    stale = trend_points.order(id: :desc).offset(KEEP_TREND_POINTS).pluck(:id)
    trend_points.where(id: stale).delete_all if stale.any?
    point
  end

  def council_seat_breakdown
    winners = zones.includes(vote_results: :candidate)
                   .filter_map { |z| z.vote_results.max_by(&:votes)&.candidate }
    winners.group_by(&:party).map do |party, cands|
      colors = cands.map(&:color).uniq
      { party: party, color: (colors.size == 1 ? colors.first : "#888888"), seats: cands.size }
    end.sort_by { |s| -s[:seats] }
  end
end
