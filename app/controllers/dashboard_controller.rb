class DashboardController < ApplicationController
  allow_unauthenticated_access

  def show
    @election = Election.current
  end
end
