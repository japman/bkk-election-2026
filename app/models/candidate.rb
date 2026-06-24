class Candidate < ApplicationRecord
  belongs_to :election
  belongs_to :zone, optional: true
  has_many :vote_results, dependent: :destroy

  validates :number, presence: true,
                     numericality: { only_integer: true, greater_than: 0 }
  validates :name, :color, presence: true
  validates :external_id, uniqueness: true, allow_nil: true
end
