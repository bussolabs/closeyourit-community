# frozen_string_literal: true

require "rails_helper"

# Board ticket (TASK B1) — contratto DOM verificato via data-test/dom-id (rules/rails/testing.md).
# Il drag-and-drop e la sincronizzazione realtime a 2 sessioni richiedono un driver JS (qui rack_test
# non esegue JS) → non coperti qui; il comportamento realtime (broadcast remove/append/replace) è
# coperto dai broadcast spec del service e del request. Vedi report TASK B1.
RSpec.describe "Member ticket board", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:done_status) { create(:ticket_status, organization: org, code: "done", label: "Done", color: "green") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "rende colonne, conteggio e card con i target dom-id e lo stato-vuoto coerente" do
    ticket = create(:ticket, organization: org, project: project, status: open_status, priority: priority)
    sign_in_as(admin_account)
    visit member_tickets_path

    expect_test "member-board"
    expect_test "board-stat-tickets"
    expect_test "board-column-open"
    expect_test "board-column-done"
    expect_test "board-count-open"
    expect_test "board-card-#{ticket.id}"

    # La card sta DENTRO il container append della sua colonna (id=board_column_<status.id>).
    expect(page).to have_css("#board_column_#{open_status.id} [data-test='board-card-#{ticket.id}']")
    # id=ticketing_ticket_<id> = dom_id(ticket): target dei broadcast (remove card / replace badge).
    expect(page).to have_css("#ticketing_ticket_#{ticket.id}")
    expect(page).to have_css("#board_count_#{open_status.id}")

    # Colonna popolata → placeholder vuoto nascosto; colonna vuota → placeholder visibile.
    within_test("board-column-open") { expect(page).to have_css("[data-board-empty]", visible: :hidden) }
    within_test("board-column-done") { expect(page).to have_css("[data-board-empty]", visible: :visible) }

    expect(page).to have_css("[data-ui--scroll-hint-target='scroller'].overflow-x-auto", visible: :all)
    expect(page).to have_css("[data-ui--scroll-hint-target='horizontal'][hidden]",
                             text: I18n.t("shared.scroll_horizontal"), visible: :all)
  end

  # CYRA-1: parità header board/lista. La board deve esporre il bottone "Chiedi ai ticket"
  # (ask_member_tickets_path, prima solo sulla lista) e la coppia di chip conteggi tickets + in corso.
  it "espone il bottone Chiedi ai ticket e i chip conteggi (totale + in corso) nell'header" do
    doing = create(:ticket_status, organization: org, code: "doing", label: "Doing", color: "indigo", category: :in_progress)
    create(:ticket, organization: org, project: project, status: open_status, priority: priority)
    create(:ticket, organization: org, project: project, status: doing, priority: priority)

    sign_in_as(admin_account)
    visit member_tickets_path

    expect(page).to have_css("[data-test='tickets-ask'][href='#{ask_member_tickets_path}']")
    expect(page).to have_css("[data-test='board-stat-tickets']", text: "2")
    expect(page).to have_css("[data-test='board-stat-in-progress']", text: "1")
  end

  it "espone una sottoscrizione realtime per ogni progetto visibile sulla pagina board" do
    sign_in_as(admin_account)
    visit member_tickets_path

    signed = page.all("turbo-cable-stream-source", visible: :all).map { |el| el["signed-stream-name"] }
    decoded = signed.compact.filter_map { |name| Turbo::StreamsChannel.verified_stream_name(name) }
    expect(decoded).to include(Realtime::Streams.project_board(project))
  end

  # I filtri (Ui::SelectComponent) si applicano in auto-submit via JS; sotto rack_test verifichiamo
  # il contratto server: la board rende la toolbar e, coi param filtro nell'URL, mostra solo le card
  # che matchano. Selettori solo data-test (rules/rails/testing.md).
  it "rende la toolbar filtri e, coi param nell'URL, filtra le card della board" do
    other_project = create(:project, organization: org, name: "Marketing", key: "MKT")
    mine = create(:ticket, organization: org, project: project, status: open_status, priority: priority)
    elsewhere = create(:ticket, organization: org, project: other_project, status: open_status, priority: priority)
    sign_in_as(admin_account)

    visit member_tickets_path
    expect_test "board-toolbar"

    visit member_tickets_path(project_id: [ project.id ])
    expect_test "board-card-#{mine.id}"
    expect(page).not_to have_css("[data-test='board-card-#{elsewhere.id}']")
  end
end
