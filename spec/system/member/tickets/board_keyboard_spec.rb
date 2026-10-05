# frozen_string_literal: true

require "rails_helper"

# Board Kanban operabile da tastiera + ARIA (WP2.9, a11y). Il riordino da tastiera riusa lo STESSO
# PATCH del drop di mouse (Ticketing::ChangeStatus): grab (Spazio) → freccia → drop (Spazio) cambia
# lo status del ticket; Esc annulla senza persistere. Richiede un browser reale (Stimulus deve
# connettersi): il gating js (driver Chrome headless + skip se manca Chrome) è condiviso in
# `spec/support/js_system.rb`. Opt-in esplicito: JS_SYSTEM_SPECS=1.
RSpec.describe "Member ticket board — tastiera + ARIA", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  # Due colonne ordinate per position: Open (0, sinistra) → Doing (1, adiacente a destra).
  let!(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber", position: 0) }
  let!(:doing_status) { create(:ticket_status, organization: org, code: "doing", label: "Doing", color: "sky", position: 1) }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }
  let!(:ticket) do
    create(:ticket, organization: org, project: project, status: open_status, priority: priority, title: "Broken checkout")
  end

  let(:owner) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  it "espone le colonne come liste ARIA etichettate dallo stato, con le card come listitem" do
    sign_in_as(owner)
    visit member_tickets_path
    expect_test "member-board"

    within_test("board-column-open") do
      list = find("[data-board-list]", visible: :all)
      expect(list[:role]).to eq("list")
      expect(list[:"aria-label"]).to include(open_status.label)
      # La card resta <a href> (link nativo) ma role=listitem la struttura come voce della lista.
      expect(find("[data-test='board-card-#{ticket.id}']")[:role]).to eq("listitem")
    end
    within_test("board-column-doing") do
      expect(find("[data-board-list]", visible: :all)[:role]).to eq("list")
      expect(find("[data-board-list]", visible: :all)[:"aria-label"]).to include(doing_status.label)
    end
  end

  it "sposta un ticket nella colonna adiacente da tastiera (grab → freccia → drop) e ne persiste lo stato" do
    sign_in_as(owner)
    visit member_tickets_path

    card = find("[data-test='board-card-#{ticket.id}']")
    # Parte nella colonna Open.
    expect(page).to have_css("#board_column_#{open_status.id} [data-test='board-card-#{ticket.id}']")

    # Spazio → prende la card: stato "preso" persistente nell'aria-label (MAI aria-grabbed,
    # deprecato) + annuncio one-shot in live region col titolo.
    card.send_keys(:space)
    expect(card[:"aria-label"]).to include(ticket.title)
    expect(find("[data-test='board-live']", visible: :all).text(:all)).to include(ticket.title)

    # Freccia destra → anteprima nella colonna adiacente (Doing), senza ancora persistere.
    card.send_keys(:arrow_right)
    expect(page).to have_css("#board_column_#{doing_status.id} [data-test='board-card-#{ticket.id}']")
    expect(find("[data-test='board-live']", visible: :all).text(:all)).to include(doing_status.label)

    # Spazio → rilascia: PATCH dello status (stessa fetch del drop di mouse) + aria-label rimosso.
    card.send_keys(:space)
    expect(card[:"aria-label"]).to be_nil
    wait_until("lo status del ticket è passato a Doing") { ticket.reload.status_id == doing_status.id }
    expect(page).to have_css("#board_column_#{doing_status.id} [data-test='board-card-#{ticket.id}']")
  end

  it "Esc annulla la presa: la card torna nella colonna d'origine e lo stato non cambia" do
    sign_in_as(owner)
    visit member_tickets_path

    card = find("[data-test='board-card-#{ticket.id}']")
    card.send_keys(:space)          # grab
    card.send_keys(:arrow_right)    # anteprima in Doing
    expect(page).to have_css("#board_column_#{doing_status.id} [data-test='board-card-#{ticket.id}']")

    card.send_keys(:escape)         # annulla
    expect(card[:"aria-label"]).to be_nil
    # Torna in Open, nessun PATCH → status invariato.
    expect(page).to have_css("#board_column_#{open_status.id} [data-test='board-card-#{ticket.id}']")
    expect(ticket.reload.status_id).to eq(open_status.id)
  end
end
