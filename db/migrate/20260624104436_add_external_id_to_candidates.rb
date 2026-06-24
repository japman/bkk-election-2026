class AddExternalIdToCandidates < ActiveRecord::Migration[8.1]
  def change
    add_column :candidates, :external_id, :string
    add_index :candidates, :external_id, unique: true, where: "external_id IS NOT NULL"
  end
end
