# frozen_string_literal: true

require "rails_helper"

# Integrazione Parte B (F3): il select milestone è un Ui::SelectComponent searchable (regola
# forms-select). Filtrare per progetto (ticket_milestone_controller.js) nasconde/disabilita le
# milestone ALTRUI nel WIDGET stesso (non solo sugli attributi del <select> nativo), e cambiare
# progetto resetta la scelta non più valida — dispatchando "ui--select:refresh" perché ui--select
# si ri-sincronizzi (vedi ui/select_controller.js). Richiede un browser reale (Stimulus deve
# connettersi): gating js in spec/support/js_system.rb.
RSpec.describe "Ticket form — milestone dipendente dal progetto (searchable)", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project_a) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:project_b) { create(:project, organization: org, name: "Backoffice", key: "BKO") }
  let!(:milestone_a) { create(:milestone, project: project_a, label: "v1.0 Storefront") }
  let!(:milestone_b) { create(:milestone, project: project_b, label: "v1.0 Backoffice") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }

  let(:account) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  def combobox_for(test_id)
    find("select[data-test='#{test_id}']", visible: :all).find(:xpath, "..")
  end

  def choose_option(combo, label)
    combo.find("button[aria-haspopup='listbox']").click
    combo.find("[role='option']", text: label).click
  end

  it "filtra le milestone del widget al cambio progetto e resetta la scelta non più valida" do
    sign_in_as(account)
    visit new_member_ticket_path
    expect(page).to have_css("[data-test='ticket-form']")

    project_combo    = combobox_for("ticket-project")
    milestone_combo  = combobox_for("ticket-milestone")
    milestone_native = milestone_combo.find("select[data-test='ticket-milestone']", visible: :all)

    # Nessun progetto scelto: project_id="" → nessuna milestone corrisponde (refresh() a connect()
    # le ha già hidden/disabled) — il pannello si apre vuoto.
    milestone_combo.find("button[aria-haspopup='listbox']").click
    expect(milestone_combo).to have_no_css("[role='option']", text: "v1.0 Storefront")
    expect(milestone_combo).to have_no_css("[role='option']", text: "v1.0 Backoffice")
    milestone_combo.find("button[aria-haspopup='listbox']").click # richiude

    # Sceglie Storefront dal WIDGET progetto (dispatcha "change" bubbles:true → delegato dal form a
    # ticket-milestone#refresh, esattamente come farebbe il <select> nativo pre-migrazione).
    choose_option(project_combo, "Storefront")

    milestone_combo.find("button[aria-haspopup='listbox']").click
    expect(milestone_combo).to have_css("[role='option']", text: "v1.0 Storefront")
    expect(milestone_combo).to have_no_css("[role='option']", text: "v1.0 Backoffice")

    milestone_combo.find("[role='option']", text: "v1.0 Storefront").click
    expect(milestone_combo.find("button[aria-haspopup='listbox']")).to have_text("v1.0 Storefront")
    expect(milestone_native.value).to eq(milestone_a.id.to_s)

    # Cambia progetto a Backoffice: la milestone scelta (di Storefront) non gli appartiene più →
    # reset automatico a "No milestone" + il widget si aggiorna SENZA riaprire manualmente.
    choose_option(project_combo, "Backoffice")

    expect(milestone_combo.find("button[aria-haspopup='listbox']"))
      .to have_text(I18n.t("member.tickets.form.milestone_none"))
    expect(milestone_native.value).to eq("")

    milestone_combo.find("button[aria-haspopup='listbox']").click
    expect(milestone_combo).to have_css("[role='option']", text: "v1.0 Backoffice")
    expect(milestone_combo).to have_no_css("[role='option']", text: "v1.0 Storefront")
  end
end
