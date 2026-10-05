# frozen_string_literal: true

require "rails_helper"

# CYRA-651 — la barra dei filtri della coda: tre menu a tendina al posto delle tre file di chip.
# Serve un browser vero: un filtro non ancora acceso si aggiunge dal menu «Filtri» (Stimulus
# ui--filter-bar) e la scelta si applica da sé alla chiusura del menu (ui--select). Gating js
# condiviso (skip senza Chrome, opt-in JS_SYSTEM_SPECS=1).
RSpec.describe "Approvazioni — barra dei filtri (CYRA-651)", :js, type: :system do
  let(:org) { create(:organization, name: "Demo Org") }
  let(:owner) { create(:account, name: "Olivia") }
  let(:project) { create(:project, organization: org, name: "closeyourit-rails", key: "CYRA") }
  let(:altro) { create(:project, organization: org, name: "closeyourit-cli", key: "CYCL") }
  let(:review_status) { create(:ticket_status, :in_review, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def review_ticket(project_record, title)
    create(:ticket, organization: org, project: project_record,
                    status: review_status, reviewer: owner, title:)
  end

  it "dal menu «Filtri» si sceglie un progetto e la coda si restringe da sé" do
    review_ticket(project, "Roba mia")
    review_ticket(altro, "Roba dell'altro")
    sign_in_as(owner)

    visit member_home_approvals_path
    expect(page).to have_css("[data-test='approvals-board']")
    expect(page).to have_content("Roba dell'altro")

    click_on_test "approvals-filters-filters-menu"
    click_on_test "filter-menu-project"

    # Scelto il filtro dal menu, il suo elenco si apre da sé: non serve un secondo clic sul campo.
    combo = find("select[data-test='approvals-filter-project']", visible: :all).find(:xpath, "..")
    combo.find("[role='option']", text: "#{altro.key} · #{altro.name}").click
    # Chiuso il menu la barra si invia da sola: nessun bottone da premere.
    find("body").click

    expect(page).to have_no_content("Roba mia")
    expect(page).to have_content("Roba dell'altro")
    expect(page).to have_current_path(/project=#{altro.key}/)
  end
end
