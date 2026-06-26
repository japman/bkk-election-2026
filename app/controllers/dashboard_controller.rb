class DashboardController < ApplicationController
  allow_unauthenticated_access

  def show
    @election = Election.current
    @no_session = true
    expires_in 5.seconds, public: true, "stale-while-revalidate": 30
  end

  def news
    render layout: false
  end
end
