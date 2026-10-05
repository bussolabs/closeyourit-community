# frozen_string_literal: true

require "rails_helper"

# Board Kanban: paginazione per colonna, colonne riducibili con preferenza persistita, e drop su una
# colonna ridotta che la riapre (CYRA-390). Richiede un browser reale (Stimulus deve connettersi):
# gating js condiviso in spec/support/js_system.rb, opt-in con JS_SYSTEM_SPECS=1.
RSpec.describe "Member ticket board — paginazione e colonne riducibili", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  # Due colonne ordinate per position: Open (0, sinistra) → Resolved (1, adiacente a destra, conclusa).
  let!(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber", position: 0) }
  let!(:done_status) { create(:ticket_status, :done, organization: org, code: "resolved", label: "Resolved", color: "emerald", position: 1) }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }
  let!(:ticket) do
    create(:ticket, organization: org, project: project, status: open_status, priority: priority, title: "Broken checkout")
  end

  let(:owner) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  def column_collapsed?(code)
    find("[data-test='board-column-#{code}']")["data-collapsed"]
  end

  it "riduce una colonna e ricorda la scelta alla ricarica" do
    sign_in_as(owner)
    visit member_tickets_path
    # La colonna di lavoro vivo (Open) parte aperta; la conclusa (Resolved) parte ridotta di default.
    expect(column_collapsed?("open")).to eq("false")

    find("[data-test='board-collapse-open']").click
    expect(column_collapsed?("open")).to eq("true")
    # La scelta è persistita sull'account (non solo nel DOM): la ricarica la ritrova.
    wait_until("la colonna Open risulta ridotta sull'account") { owner.reload.board_collapsed_statuses.include?("open") }

    visit member_tickets_path
    expect(column_collapsed?("open")).to eq("true")
    # Dalla barra ridotta si riapre, e anche questo si ricorda.
    find("[data-test='board-expand-open']").click
    wait_until("la colonna Open risulta riaperta sull'account") { owner.reload.board_collapsed_statuses.exclude?("open") }
    expect(column_collapsed?("open")).to eq("false")
  end

  it "carica il resto di una colonna con «mostra altre»" do
    create_list(:ticket, Ticketing::Constants::BOARD_COLUMN_PAGE + 2,
                organization: org, project: project, status: open_status, priority: priority)
    sign_in_as(owner)
    visit member_tickets_path

    cards = "#board_column_#{open_status.id} [data-ticket-board-target='card']"
    # Primo blocco: 20 card (le 22+1 iniziali del ticket base sono oltre la soglia) + «mostra altre».
    expect(page).to have_css(cards, count: Ticketing::Constants::BOARD_COLUMN_PAGE)
    find("[data-test='board-more-open']").click
    # L'append incrementale porta a vista tutte le card della colonna.
    expect(page).to have_css(cards, count: Ticketing::Constants::BOARD_COLUMN_PAGE + 3)
    expect(page).to have_no_css("[data-test='board-more-open']")
  end

  it "trascinando da tastiera su una colonna ridotta la riapre e la card resta a vista" do
    owner.update!(board_collapsed_statuses: [ "resolved" ])
    sign_in_as(owner)
    visit member_tickets_path
    expect(column_collapsed?("resolved")).to eq("true")

    card = find("[data-test='board-card-#{ticket.id}']")
    card.send_keys(:space)        # prende la card
    card.send_keys(:arrow_right)  # la porta verso la colonna Resolved (ridotta) → si riapre
    expect(column_collapsed?("resolved")).to eq("false")

    card.send_keys(:space)        # rilascia → persiste il cambio di stato
    wait_until("lo status del ticket è passato a Resolved") { ticket.reload.status_id == done_status.id }
    # La card è finita nella colonna Resolved ed è visibile (non nascosta dietro il collasso).
    expect(page).to have_css("#board_column_#{done_status.id} [data-test='board-card-#{ticket.id}']")
  end
end
