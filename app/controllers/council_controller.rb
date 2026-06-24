class CouncilController < ApplicationController
  allow_unauthenticated_access

  def show
    @election = Election.council
  end
end
