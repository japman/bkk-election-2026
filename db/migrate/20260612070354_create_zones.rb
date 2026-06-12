class CreateZones < ActiveRecord::Migration[8.1]
  def change
    create_table :zones do |t|
      t.references :election, null: false, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.integer :grid_col, null: false
      t.integer :grid_row, null: false
      t.timestamps
    end
    add_index :zones, [:election_id, :code], unique: true
  end
end
