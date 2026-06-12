class ZoneStat < ApplicationRecord
  belongs_to :zone
  has_many :result_revisions, as: :recordable, dependent: :destroy

  validates :zone_id, uniqueness: true
  validates :eligible_voters, :turnout, :bad_ballots, :no_vote,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :counted_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :source, inclusion: { in: %w[api manual] }
end
