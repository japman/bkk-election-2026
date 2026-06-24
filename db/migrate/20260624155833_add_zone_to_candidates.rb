class AddZoneToCandidates < ActiveRecord::Migration[8.1]
  def change
    add_reference :candidates, :zone, null: true, foreign_key: true
    remove_index :candidates, column: [ :election_id, :number ], name: "index_candidates_on_election_id_and_number"
    add_index :candidates, [ :election_id, :number ], unique: true,
              where: "zone_id IS NULL", name: "idx_candidates_election_number_governor"
    add_index :candidates, [ :election_id, :zone_id, :number ], unique: true,
              where: "zone_id IS NOT NULL", name: "idx_candidates_election_zone_number_council"
  end
end
