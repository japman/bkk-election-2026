class VoteResult < ApplicationRecord
  belongs_to :zone
  belongs_to :candidate
  has_many :result_revisions, as: :recordable, dependent: :destroy

  validates :votes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :candidate_id, uniqueness: { scope: :zone_id }
  validates :source, inclusion: { in: %w[api manual] }
end
