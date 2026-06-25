class CouncilController < ApplicationController
  allow_unauthenticated_access

  def show
    @election = Election.council
    @no_session = true
    expires_in 5.seconds, public: true, "stale-while-revalidate": 30
  end
end
