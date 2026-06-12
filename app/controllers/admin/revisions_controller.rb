class Admin::RevisionsController < ApplicationController
  def index
    @revisions = ResultRevision.order(created_at: :desc).limit(200)
  end
end
