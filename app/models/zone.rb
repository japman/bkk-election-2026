class Zone < ApplicationRecord
  belongs_to :election
  has_many :vote_results, dependent: :destroy
  has_one :zone_stat, dependent: :destroy

  validates :code, presence: true, uniqueness: { scope: :election_id }
  validates :name, :grid_col, :grid_row, presence: true
end
