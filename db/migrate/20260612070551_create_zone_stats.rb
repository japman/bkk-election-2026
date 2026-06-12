class CreateZoneStats < ActiveRecord::Migration[8.1]
  def change
    create_table :zone_stats do |t|
      t.references :zone, null: false, foreign_key: true, index: { unique: true }
      t.integer :eligible_voters, null: false, default: 0
      t.integer :turnout, null: false, default: 0
      t.integer :bad_ballots, null: false, default: 0
      t.integer :no_vote, null: false, default: 0
      t.decimal :counted_percent, precision: 5, scale: 2, null: false, default: 0
      t.string :source, null: false, default: "api"

      t.timestamps
    end
  end
end
