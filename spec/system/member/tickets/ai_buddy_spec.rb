# frozen_string_literal: true

require "rails_helper"

# AI Buddy: bottone nell'header del form NUOVO ticket che apre un <dialog> di composizione AI. Driver
# rack_test = niente JS: si verifica solo il RENDERING (bottone + modale presenti sul form generico e
# sui progetti senza assistente rapido; assenti quando l'assistente rapido bug è già presente → un solo
# affordance AI per schermo). Il <dialog> chiuso è nascosto (display:none), quindi il suo contenuto si
# asserisce con visible: :all. Il flusso JS ask→review→"Riempi ora" è coperto dal request spec
# (Member::Tickets#compose) e dallo unit del service (Ticketing::ComposeTicket).
RSpec.describe "Member AI Buddy (compose ticket)", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "form nuovo generico (nessun progetto locked) → bottone AI Buddy nell'header + modale nel DOM" do
    create(:project, organization: org, name: "Storefront", key: "STR")
    sign_in_as(owner_account)
    visit new_member_ticket_path

    expect_test "ticket-compose-open"
    expect(page).to have_css("[data-test='ticket-compose-panel']", visible: :all)
    expect(page).to have_css("[data-test='ticket-compose-prompt']", visible: :all)
    expect(page).to have_css("[data-test='ticket-compose-run']", visible: :all)
    # "Riempi ora" parte nascosto (attributo [hidden], non classe .hidden): compare solo dopo la bozza (JS).
    expect(page).to have_css("[data-test='ticket-compose-fill'][hidden]", visible: :all)
  end

  it "creazione da progetto SENZA flag rapido → AI Buddy presente (unico affordance AI)" do
    project = create(:project, organization: org, name: "Storefront", key: "STR", quick_bug_report_enabled: false)
    sign_in_as(owner_account)
    visit new_member_ticket_path(project_id: project)

    expect_test "ticket-compose-open"
    expect(page).to have_no_css("[data-test='ticket-quick-panel']")
  end

  it "creazione da progetto CON flag rapido → l'assistente rapido copre, AI Buddy nascosto" do
    project = create(:project, organization: org, name: "Storefront", key: "STR", quick_bug_report_enabled: true)
    sign_in_as(owner_account)
    visit new_member_ticket_path(project_id: project)

    expect_test "ticket-quick-panel"
    expect(page).to have_no_css("[data-test='ticket-compose-open']", visible: :all)
    expect(page).to have_no_css("[data-test='ticket-compose-panel']", visible: :all)
  end
end
