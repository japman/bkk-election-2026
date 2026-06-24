class AddPartyLogoUrlToCandidates < ActiveRecord::Migration[8.1]
  def change
    add_column :candidates, :party_logo_url, :string
  end
end
