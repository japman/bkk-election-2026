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

  # อันดับผู้สมัคร — ใช้ total_votes ที่ ECT คำนวณให้ (candidates endpoint) เมื่อมีค่าแล้ว
  # ไม่งั้น fallback เป็นผลรวมราย 50 เขต (ก่อน ingest candidate-total ครั้งแรก / ใน test)
  def leaderboard
    @leaderboard ||=
      if candidates.where("total_votes > 0").exists?
        candidates.order(total_votes: :desc, number: :asc).to_a
      else
        # fallback (ก่อน ingest candidate-total ครั้งแรก / ใน test): รวมราย 50 เขต
        # set total_votes ใน memory (ไม่ save) เลี่ยงชนชื่อคอลัมน์จริงตอน ORDER BY
        sums = VoteResult.joins(:candidate).where(candidates: { election_id: id })
                         .group(:candidate_id).sum(:votes)
        cands = candidates.to_a
        cands.each { |c| c.total_votes = sums[c.id].to_i }
        cands.sort_by { |c| [ -c.total_votes, c.number ] }
      end
  end

  # ยอดรวมทั้งหมด — ผลรวม total_votes ของผู้สมัคร (ECT) เมื่อมี, ไม่งั้นผลรวมราย 50 เขต
  def total_votes
    col = candidates.sum(:total_votes)
    col.positive? ? col : VoteResult.joins(:zone).where(zones: { election_id: id }).sum(:votes)
  end

  # % นับคะแนน — ใช้ค่า ECT ตรง (stationsReported/totalStations) เมื่อมี
  # ไม่งั้น fallback เป็นเฉลี่ยทั้ง 50 เขต (เขตที่ยังไม่รายงานนับเป็น 0)
  def counted_percent
    return coverage_percent.round(1) if coverage_percent.to_f.positive?
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
