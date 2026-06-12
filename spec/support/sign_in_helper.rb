module SignInHelper
  def sign_in_as(user, password: "election2026")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  def create_admin
    User.create!(email_address: "ops@dailynews.local", password: "election2026")
  end
end

RSpec.configure { |config| config.include SignInHelper, type: :request }
