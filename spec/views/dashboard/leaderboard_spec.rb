require "rails_helper"

RSpec.describe "dashboard/_leaderboard", type: :view do
  it "renders a photo img when photo_url is present, else a letter avatar" do
    e = build_election(zones: 0, candidates: 2)
    e.candidates.order(:number).first.update!(photo_url: "/images/candidates/1.png")
    # candidate 2 left without photo_url
    render partial: "dashboard/leaderboard", locals: { election: e }
    expect(rendered).to include('src="/images/candidates/1.png"')
    expect(rendered).to include('class="avatar"') # fallback letter avatar still present for the photo-less one
  end
end
