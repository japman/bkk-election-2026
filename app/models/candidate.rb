class Candidate < ApplicationRecord
  belongs_to :election
  has_many :vote_results, dependent: :destroy

  validates :number, presence: true, uniqueness: { scope: :election_id },
                     numericality: { only_integer: true, greater_than: 0 }
  validates :name, :color, presence: true
  validates :external_id, uniqueness: true, allow_nil: true
end
