class CreateElections < ActiveRecord::Migration[8.1]
  def change
    create_table :elections do |t|
      t.string :name, null: false
      t.date :election_date, null: false
      t.string :status, null: false, default: "scheduled"
      t.string :data_mode, null: false, default: "api"
      t.timestamps
    end
  end
end
