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

  it "renders a party-logo img for candidates with party_logo_url, and omits it for those without" do
    e = build_election(zones: 0, candidates: 5)
    candidates = e.candidates.order(:number)
    # Candidates ranked 4th (index 3) and 5th (index 4) appear in the table rows (not the podium).
    with_logo    = candidates[3]
    without_logo = candidates[4]
    with_logo.update!(party_logo_url: "/images/parties/logo.png")
    without_logo.update!(party_logo_url: nil)

    render partial: "dashboard/leaderboard", locals: { election: e }

    # Split rendered HTML into individual <tr> … </tr> chunks for precise assertions.
    rows = rendered.scan(/<tr>.*?<\/tr>/m)

    with_logo_row    = rows.find { |r| r.include?(with_logo.name) }
    without_logo_row = rows.find { |r| r.include?(without_logo.name) }

    expect(with_logo_row).not_to be_nil
    expect(without_logo_row).not_to be_nil

    # The row with a logo URL must contain the party-logo img pointing to that URL.
    expect(with_logo_row).to include('class="party-logo"')
    expect(with_logo_row).to include('src="/images/parties/logo.png"')

    # The row without a logo URL must NOT contain any party-logo img.
    expect(without_logo_row).not_to include('class="party-logo"')
  end
end
