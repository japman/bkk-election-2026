class CreateResultRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :result_revisions do |t|
      t.references :recordable, polymorphic: true, null: false
      t.jsonb :old_values, null: false, default: {}
      t.jsonb :new_values, null: false, default: {}
      t.string :source, null: false
      t.string :editor

      t.timestamps
    end
    add_index :result_revisions, :created_at
  end
end
