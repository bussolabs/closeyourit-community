# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Password reset", type: :system do
  before { driven_by(:rack_test) }

  let!(:account) { create(:account, email: "ada@example.com") }

  it "la richiesta reset reindirizza al login con messaggio" do
    visit new_password_path
    fill_test "forgot-email", with: "ada@example.com"
    click_on_test "forgot-submit"

    expect(page).to have_current_path(login_path)
    expect_test "flash-notice"
  end

  it "imposta una nuova password dal link" do
    token = account.generate_token_for(:password_reset)
    visit edit_password_path(token)
    fill_test "reset-password", with: "Nuova123!"
    fill_test "reset-password-confirmation", with: "Nuova123!"
    click_on_test "reset-submit"

    expect(page).to have_current_path(login_path)
    expect_test "flash-notice"
    expect(account.reload.authenticate("Nuova123!")).to be_truthy
  end
end
