# frozen_string_literal: true

require "rails_helper"

# Dipendenze tra ticket end-to-end (rack_test: niente JS → il Ui::SelectComponent resta un <select>
# nativo submittabile, e si esercita il flusso server-side completo aggiungi/rimuovi + badge board).
# Selettori per data-test, mai per testo.
RSpec.describe "Member tickets — dipendenze", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org) }
  let!(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:done_status) { create(:ticket_status, :done, organization: org, code: "done", label: "Done", color: "emerald") }
  let(:ticket) { create(:ticket, organization: org, project: project, status: open_status, title: "Ticket A") }
  # let! (non lazy): dev'esistere PRIMA del visit, altrimenti non è tra i candidati e il form add non compare.
  let!(:blocker) { create(:ticket, organization: org, project: project, status: open_status, title: "Prerequisito B") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  # Scenario 1
  it "aggiunge un prerequisito dalla show: compare tra le dipendenze" do
    sign_in_as(owner)
    visit member_ticket_path(ticket)

    select "#{blocker.code} · #{blocker.title}", from: "blocker_id"
    click_on_test "dependency-add"

    expect_test "ticket-dependencies"
    expect(page).to have_css("[data-test='dependency-target-#{blocker.id}']")
    expect(ticket.reload.blockers).to include(blocker)
  end

  # Scenario 2
  it "rimuove un prerequisito esistente: sparisce dalla lista" do
    dependency = create(:ticket_dependency, ticket: ticket, blocker: blocker)
    sign_in_as(owner)
    visit member_ticket_path(ticket)

    expect_test "ticket-dependency-#{dependency.id}"
    click_on_test "ticket-dependency-remove-#{dependency.id}"

    expect(page).not_to have_css("[data-test='ticket-dependency-#{dependency.id}']")
    expect(ticket.reload.blockers).not_to include(blocker)
  end

  # Scenario 5: il select esclude sé stesso e i blocker già associati (value = uuid, match esatto).
  it "il select esclude il ticket stesso e i blocker già associati; il candidato libero resta" do
    create(:ticket_dependency, ticket: ticket, blocker: blocker)
    other = create(:ticket, organization: org, project: project, status: open_status, title: "Candidato C")
    sign_in_as(owner)
    visit member_ticket_path(ticket)

    within_test "dependency-blocker-select" do
      expect(page).to have_css("option[value='#{other.id}']")
      expect(page).not_to have_css("option[value='#{ticket.id}']")
      expect(page).not_to have_css("option[value='#{blocker.id}']")
    end
  end

  # Scenario 3
  it "board: la card di un ticket con prerequisito aperto mostra il badge 'bloccato'; risolto → sparisce" do
    create(:ticket_dependency, ticket: ticket, blocker: blocker)
    sign_in_as(owner)

    visit member_tickets_path
    expect_test "board-card-blocked-#{ticket.id}"

    blocker.update!(status: done_status)
    visit member_tickets_path
    expect(page).not_to have_css("[data-test='board-card-blocked-#{ticket.id}']")
  end

  # Scenario 4: senza tickets.edit la sezione è in sola lettura (nessun form di aggiunta/rimozione).
  it "in sola lettura (senza gestione) mostra le dipendenze ma nessun form" do
    reader = create(:account)
    create(:membership, account: reader, organization: org, role: :member)
    create(:project_membership, account: reader, project: project)
    create(:ticket_dependency, ticket: ticket, blocker: blocker)

    sign_in_as(reader)
    visit member_ticket_path(ticket)

    expect_test "ticket-dependencies"
    expect(page).to have_css("[data-test='dependency-target-#{blocker.id}']")
    expect(page).not_to have_css("[data-test='dependency-form']")
    expect(page).not_to have_css("[data-test='dependency-blocker-select']")
  end
end
