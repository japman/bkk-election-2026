class CreateCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :candidates do |t|
      t.references :election, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :name, null: false
      t.string :party
      t.string :color, null: false, default: "#0E7A3D"
      t.string :photo_url
      t.timestamps
    end
    add_index :candidates, [ :election_id, :number ], unique: true
  end
end
