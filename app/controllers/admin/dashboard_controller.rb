class Admin::DashboardController < ApplicationController
  def index
    @election = Election.current
    @zones = @election.zones.includes(:zone_stat).order(:code)
  end
end
