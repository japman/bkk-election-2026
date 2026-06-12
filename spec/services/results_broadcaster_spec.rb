require "rails_helper"

RSpec.describe ResultsBroadcaster, type: :channel do
  include ElectionSetup

  it "broadcasts replacements for all 4 live regions" do
    e = build_election(zones: 1, candidates: 1)
    expect {
      ResultsBroadcaster.new(e).broadcast_all
    }.to have_broadcasted_to("results").exactly(4).times
  end
end
