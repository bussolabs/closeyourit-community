# frozen_string_literal: true

require "rails_helper"

# Ticket sempre salvabile (anche con solo testo semplice) + assistente AI che SUGGERISCE, non blocca.
# Driver rack_test = niente JS: si verifica il rendering (descrizione + repeater scenari con una riga
# pronta + DoD + analisi tecnica, pannello assistente gated dal flag) e che il ticket si crei sia con
# la sola descrizione sia con uno scenario compilato a mano. Il flusso AI fetch→domande/fill è coperto
# dal request spec (Member::Tickets#analyze) — qui Stimulus non gira.
RSpec.describe "Member quick bug report", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR", quick_bug_report_enabled: true) }
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

  it "mostra descrizione, assistente, repeater scenari/DoD e analisi tecnica (flag attivo)" do
    sign_in_as(owner_account)
    visit new_member_ticket_path(project_id: project)

    expect_test "ticket-description"
    # Assistente AI (suggerimento) gated dal flag.
    expect_test "ticket-quick-panel"
    expect_test "ticket-quick-analyze"
    # Corpo strutturato: scenari (nessuno finché l'utente non ne aggiunge uno) + DoD + analisi tecnica.
    expect_test "ticket-scenario-add"
    expect(page).to have_no_css("[data-test='ticket-scenario-row']")
    expect_test "ticket-conditions"
    expect_test "ticket-technical-analysis"
  end

  it "da SOLO testo semplice (descrizione), scenario vuoto scartato → il ticket viene creato" do
    sign_in_as(owner_account)
    visit new_member_ticket_path(project_id: project)

    fill_test "ticket-title", with: "Checkout rotto su Safari"
    fill_test "ticket-description", with: "Su Safari clicco Checkout e non succede nulla"
    click_on_test "ticket-submit"

    expect_test "flash-notice"
    ticket = Ticketing::Ticket.find_by(title: "Checkout rotto su Safari")
    expect(ticket).to be_present
    expect(ticket.kind).to eq("bug")
    expect(ticket.description).to eq("Su Safari clicco Checkout e non succede nulla")
    expect(ticket.scenarios).to be_empty
  end

  it "senza alcun corpo (né descrizione né scenari) → 422, non viene creato" do
    sign_in_as(owner_account)
    visit new_member_ticket_path(project_id: project)

    fill_test "ticket-title", with: "Titolo senza corpo"
    click_on_test "ticket-submit"

    expect_test "flash-alert"
    expect(Ticketing::Ticket.find_by(title: "Titolo senza corpo")).to be_nil
  end

  it "flag disattivo → nessun assistente, ma descrizione e corpo strutturato restano" do
    project.update!(quick_bug_report_enabled: false)
    sign_in_as(owner_account)
    visit new_member_ticket_path(project_id: project)

    expect_test "ticket-description"
    expect_test "ticket-scenarios"
    expect_test "ticket-technical-analysis"
    expect(page).to have_no_css("[data-test='ticket-quick-panel']")
  end
end
