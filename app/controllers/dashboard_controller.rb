class DashboardController < ApplicationController
  def show
    @election = Election.current
  end
end
