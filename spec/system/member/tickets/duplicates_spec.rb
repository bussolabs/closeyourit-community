# frozen_string_literal: true

require "rails_helper"

# Pannello "ticket simili" nel form new (rack_test: niente JS → si verifica il rendering
# progressive-enhancement e che il form resti salvabile; il flusso fetch è nel request spec).
RSpec.describe "Member tickets — pannello duplicati", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org) }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "il form new monta il pannello (nascosto) e il ticket si crea comunque" do
    sign_in_as(owner)
    visit new_member_ticket_path(project_id: project)

    expect(page).to have_css("[data-test='ticket-duplicates-panel']", visible: :hidden)

    fill_test "ticket-title", with: "Crash al login"
    fill_test "ticket-description", with: "Descrizione del problema"
    click_on_test "ticket-submit"

    expect(Ticketing::Ticket.find_by(title: "Crash al login")).to be_present
  end

  it "il pannello sta DENTRO il form: è così che le spunte arrivano al salvataggio" do
    sign_in_as(owner)
    visit new_member_ticket_path(project_id: project)

    # Spostarlo fuori non romperebbe nessuna pagina: smetterebbe solo di collegare, in silenzio.
    expect(page).to have_css("[data-test='ticket-form'] [data-test='ticket-duplicates-panel']",
                             visible: :hidden)
  end

  it "le spunte tornate indietro da un errore restano nel form" do
    twin = create(:ticket, organization: org, project: project, status: status, priority: priority)

    sign_in_as(owner)
    # Titolo vuoto → il salvataggio fallisce e la pagina si ripresenta: la scelta non deve sparire
    # insieme al messaggio d'errore.
    page.driver.post(member_tickets_path, project_id: project.id, title: "", kind: "bug",
                                          description: "x", status_id: status.id,
                                          priority_id: priority.id, link_ticket_ids: [ twin.id ])

    expect(page.driver.response.body).to include("name=\"link_ticket_ids[]\"")
    expect(page.driver.response.body).to include(twin.id)
  end

  it "il form edit NON monta il pannello duplicati" do
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)

    sign_in_as(owner)
    visit edit_member_ticket_path(ticket)

    expect(page).to have_no_css("[data-test='ticket-duplicates-panel']", visible: :all)
  end
end
