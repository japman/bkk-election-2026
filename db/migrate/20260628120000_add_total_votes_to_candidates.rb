class AddTotalVotesToCandidates < ActiveRecord::Migration[8.1]
  # Authoritative per-candidate total straight from the ECT candidates endpoint
  # (data.candidates[].totalVotes). Used for the overall leaderboard instead of
  # summing 50 zones, so the headline numbers can't drift from the source.
  # Default 0 → Election#leaderboard falls back to the per-zone sum until the
  # first candidate-total ingest populates it.
  def change
    add_column :candidates, :total_votes, :integer, default: 0, null: false
  end
end
