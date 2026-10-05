# frozen_string_literal: true

require "rails_helper"

# Board Kanban del workload operabile da tastiera — mirror E2E di
# spec/system/member/tickets/board_keyboard_spec.rb (fix review T8: prima il keyboard workload era
# implementato ma coperto solo da spec ARIA/non-JS, vedi task-8-report.md §Concern). Il riordino da
# tastiera riusa lo STESSO PATCH del drop di mouse (Member::Workload::ActionsController#status): grab
# (Spazio) → freccia → drop (Spazio) cambia lo status della action; Esc annulla senza persistere.
# Richiede un browser reale (Stimulus deve connettersi): gating js condiviso in spec/support/js_system.rb.
# Opt-in esplicito: JS_SYSTEM_SPECS=1.
RSpec.describe "Member workload board — tastiera + ARIA", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let(:team) { create(:team, organization: org, name: "Marketing") }
  # planned (0, sinistra) → in_progress (1, adiacente a destra): stesso ordinamento enum della board
  # (Workload::Action.statuses.keys), pattern identico al board_keyboard_spec dei ticket.
  let!(:action) { create(:workload_action, team: team, organization: org, title: "Volantini fiera") }

  let(:member) do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    create(:team_membership, team: team, account: account)
    account
  end

  it "sposta una action nella colonna adiacente da tastiera (grab → freccia → drop) e ne persiste lo stato" do
    sign_in_as(member)
    visit member_workload_actions_path

    card = find("[data-test='workload-board-card-#{action.id}']")
    # Parte nella colonna Planned.
    expect(page).to have_css("#workload_board_column_planned [data-test='workload-board-card-#{action.id}']")

    # Spazio → prende la card: stato "preso" persistente nell'aria-label (MAI aria-grabbed,
    # deprecato) + annuncio one-shot in live region col titolo.
    card.send_keys(:space)
    expect(card[:"aria-label"]).to include(action.title)
    expect(find("[data-test='workload-board-live']", visible: :all).text(:all)).to include(action.title)

    # Freccia destra → anteprima nella colonna adiacente (In progress), senza ancora persistere.
    card.send_keys(:arrow_right)
    expect(page).to have_css("#workload_board_column_in_progress [data-test='workload-board-card-#{action.id}']")

    # Spazio → rilascia: PATCH dello status (stessa fetch del drop di mouse) + aria-label rimosso.
    card.send_keys(:space)
    expect(card[:"aria-label"]).to be_nil
    wait_until("lo status della action è passato a In progress") { action.reload.status == "in_progress" }
    expect(page).to have_css("#workload_board_column_in_progress [data-test='workload-board-card-#{action.id}']")
  end

  it "Esc annulla la presa: la action torna nella colonna d'origine e lo stato non cambia" do
    sign_in_as(member)
    visit member_workload_actions_path

    card = find("[data-test='workload-board-card-#{action.id}']")
    card.send_keys(:space)          # grab
    card.send_keys(:arrow_right)    # anteprima in In progress
    expect(page).to have_css("#workload_board_column_in_progress [data-test='workload-board-card-#{action.id}']")

    card.send_keys(:escape)         # annulla
    expect(card[:"aria-label"]).to be_nil
    # Torna in Planned, nessun PATCH → status invariato.
    expect(page).to have_css("#workload_board_column_planned [data-test='workload-board-card-#{action.id}']")
    expect(action.reload.status).to eq("planned")
  end

  it "opens the collapsed cancelled column before moving a card into it from the keyboard" do
    action.update!(status: :done)
    sign_in_as(member)
    visit member_workload_actions_path

    card = find("[data-test='workload-board-card-#{action.id}']")
    card.send_keys(:space)
    card.send_keys(:arrow_right)

    expect(page).to have_css("[data-test='workload-board-column-cancelled'][data-collapsed='false']")
    expect(page).to have_css("#workload_board_column_cancelled [data-test='workload-board-card-#{action.id}']", visible: true)
  end
end
