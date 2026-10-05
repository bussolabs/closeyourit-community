# frozen_string_literal: true

require "rails_helper"

# Indicatore di connessione realtime + agganci presenza nell'header member.
# NON simula il WebSocket (rack_test non esegue JS): verifica solo che gli
# elementi server-rendered — badge e contenitori presenza — siano nell'header
# dopo il login, selezionando esclusivamente via data-test.
RSpec.describe "Member connection status", type: :system do
  before { driven_by(:rack_test) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before do
    create(:membership, account: account, organization: organization, role: :owner)
    sign_in_as(account)
  end

  it "mostra il controllo combinato di connessione e presenza nell'header" do
    expect(page).to have_current_path(root_path)
    expect_test "connection-presence-control"
    expect(page).to have_css("[data-connection-status-target='icon'].rounded-full.bg-green-500")
    expect(page.find("[data-test='presence-trigger']")[:class]).to include("md:@min-[810px]:w-auto")
  end

  it "predispone gli agganci di presenza per l'organizzazione" do
    expect_test "presence"
    expect_test "presence-list"
  end
end
