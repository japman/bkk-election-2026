class AddKindToElections < ActiveRecord::Migration[8.1]
  def change
    add_column :elections, :kind, :string, null: false, default: "governor"
  end
end
