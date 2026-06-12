class CreateVoteResults < ActiveRecord::Migration[8.1]
  def change
    create_table :vote_results do |t|
      t.references :zone, null: false, foreign_key: true
      t.references :candidate, null: false, foreign_key: true
      t.integer :votes, null: false, default: 0
      t.string :source, null: false, default: "api"

      t.timestamps
    end
    add_index :vote_results, [:zone_id, :candidate_id], unique: true
  end
end
