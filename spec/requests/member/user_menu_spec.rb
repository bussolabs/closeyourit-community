# frozen_string_literal: true

require "rails_helper"

# Contratto del menu del profilo (area member). Il menu è un <details>: senza JS le sue voci stanno
# nel DOM e si raggiungono per indirizzo, quindi il markup dice già tutto — CYRA-856 ha spostato qui
# quello che apriva un browser per leggere un nome e un collegamento.
RSpec.describe "Menu del profilo (member)", type: :request do
  let(:account) { create(:account, name: "Olivia Holt") }
  let(:org) { create(:organization, name: "Demo Org") }

  before do
    create(:membership, account: account, organization: org, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
    get root_path
  end

  # CYRA-898: the bar shows the initials, the name is the trigger's label and the menu's first row.
  it "shows the initials in the trigger and the account name in the menu" do
    doc = Nokogiri::HTML(response.body)
    trigger = doc.at_css("[data-test='member-user-menu']")

    expect(trigger.text).to include("OH")
    expect(trigger["aria-label"]).to eq("Olivia Holt")
    expect(doc.at_css("[data-test='user-menu-identity']").text).to include("Olivia Holt")
  end

  it "la voce Account porta alle preferenze" do
    voce = Nokogiri::HTML(response.body).at_css("[data-test='member-nav-preferences']")

    expect(voce["href"]).to eq(member_preferences_path)
  end
end
