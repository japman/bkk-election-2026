class Election < ApplicationRecord
  has_many :candidates, dependent: :destroy
  has_many :zones, dependent: :destroy

  enum :data_mode, { api: "api", manual: "manual" }, default: "api"

  validates :name, :election_date, presence: true

  def self.current = order(created_at: :desc).first
end
