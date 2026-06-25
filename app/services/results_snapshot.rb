# payload เดียวใช้ทั้ง polling fallback, กราฟ และ zone detail บนหน้าเว็บ
class ResultsSnapshot
  def initialize(election)
    @election = election
  end

  def as_json(*)
    @election.kind == "council" ? council_json : governor_json
  end

  private

  def governor_json
    total = @election.total_votes
    {
      updated_at: Time.current.iso8601,
      counted_percent: @election.counted_percent.to_f,
      stats: @election.stats_summary,
      candidates: @election.leaderboard.map do |c|
        { number: c.number, name: c.name, party: c.party, color: c.color,
          photo_url: c.photo_url, party_logo_url: c.party_logo_url,
          votes: c.total_votes.to_i,
          percent: total.zero? ? 0.0 : (c.total_votes * 100.0 / total).round(1) }
      end,
      zones: @election.zones.order(:code).includes(:zone_stat, vote_results: :candidate).map do |z|
        ranked = z.vote_results.sort_by { |r| -r.votes }
        st = z.zone_stat
        { code: z.code, name: z.name,
          leader_number: ranked.first&.candidate&.number,
          counted_percent: st&.counted_percent.to_f,
          stats: { eligible_voters: st&.eligible_voters.to_i, turnout: st&.turnout.to_i,
                   bad_ballots: st&.bad_ballots.to_i, no_vote: st&.no_vote.to_i },
          results: ranked.map { |r| { number: r.candidate.number, votes: r.votes } } }
      end
    }
  end

  def council_json
    districts = @election.zones.order(:code).includes(:zone_stat, vote_results: :candidate).map do |z|
      ranked = z.vote_results.sort_by { |r| -r.votes }
      w = ranked.first&.candidate
      { code: z.code, name: z.name, counted_percent: z.zone_stat&.counted_percent.to_f,
        winner: w && { number: w.number, name: w.name, party: w.party, color: w.color,
                       photo_url: w.photo_url, votes: ranked.first.votes },
        results: ranked.map { |r| { number: r.candidate.number, name: r.candidate.name,
                                    party: r.candidate.party, color: r.candidate.color,
                                    photo_url: r.candidate.photo_url, votes: r.votes } } }
    end
    seats = @election.council_seat_breakdown
    { updated_at: Time.current.iso8601, kind: "council",
      counted_percent: @election.counted_percent.to_f, seats: seats, districts: districts }
  end
end
