# จุดเดียวที่แก้ VoteResult/ZoneStat ได้ — บังคับกติกา "คะแนนห้ามลด" (spec §7)
# และบันทึก ResultRevision ทุกการเปลี่ยนแปลง
class ResultWriter
  class StaleVotesError < StandardError; end

  STAT_FIELDS = %i[eligible_voters turnout bad_ballots no_vote counted_percent].freeze

  # source: "api" | "manual" (admin) — allow_decrease ใช้ได้เฉพาะ admin ที่ confirm แล้ว
  def initialize(zone, source:, editor: nil, allow_decrease: false)
    @zone = zone
    @source = source
    @editor = editor
    @allow_decrease = allow_decrease
  end

  # votes_by_number: { เบอร์ผู้สมัคร => คะแนน }, stats: hash ตาม STAT_FIELDS
  # คืน true ถ้ามีอะไรเปลี่ยนจริง (ใช้ตัดสินใจ broadcast)
  def apply!(votes_by_number, stats: nil)
    changed = false
    ActiveRecord::Base.transaction do
      votes_by_number.each do |number, votes|
        coerced_number = number.is_a?(String) ? Integer(number, 10) : Integer(number)
        coerced_votes  = votes.is_a?(String) ? Integer(votes, 10) : Integer(votes)
        changed |= write_votes(coerced_number, coerced_votes)
      end
      changed |= write_stats(stats) if stats
    end
    changed
  end

  private

  def revision_source = @source == "api" ? "api" : "admin"

  def write_votes(number, votes)
    candidate = @zone.election.candidates.where(zone_id: [ nil, @zone.id ]).find_by!(number: number)
    result = VoteResult.find_or_initialize_by(zone: @zone, candidate: candidate)
    old = result.persisted? ? result.votes : nil
    return false if old == votes

    if old && votes < old && !@allow_decrease
      raise StaleVotesError, "zone #{@zone.code} ##{number}: #{votes} < #{old}"
    end

    result.update!(votes: votes, source: @source)
    ResultRevision.create!(recordable: result, old_values: { "votes" => old },
                           new_values: { "votes" => votes },
                           source: revision_source, editor: @editor)
    true
  end

  def write_stats(stats)
    stat = ZoneStat.find_or_initialize_by(zone: @zone)
    incoming = stats.symbolize_keys.slice(*STAT_FIELDS)
    old = incoming.keys.index_with { |f| normalize_value(stat.public_send(f)) }
    stat.assign_attributes(incoming.merge(source: @source))
    return false unless stat.changed?

    stat.save!
    ResultRevision.create!(recordable: stat, old_values: old,
                           new_values: incoming.transform_values { |v| normalize_value(v) },
                           source: revision_source, editor: @editor)
    true
  end

  def normalize_value(value)
    value.is_a?(BigDecimal) ? value.to_f : value
  end
end
