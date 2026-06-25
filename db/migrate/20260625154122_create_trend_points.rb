class CreateTrendPoints < ActiveRecord::Migration[8.1]
  def change
    create_table :trend_points do |t|
      t.references :election, null: false, foreign_key: true
      t.datetime :captured_at, null: false
      t.jsonb :votes, null: false, default: {}
      t.timestamps
    end
    add_index :trend_points, [:election_id, :captured_at]
  end
end
