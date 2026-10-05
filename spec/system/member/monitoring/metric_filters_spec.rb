# frozen_string_literal: true

require "rails_helper"

# CYRA-343 (Scenario 2) — nel dropdown del filtro «Tipo di problema» ogni voce ha sotto una riga che
# la spiega in parole semplici. Serve un browser reale: lo Stimulus ui--select rende la descrizione
# dalla `data-description` dell'option. Gating js condiviso (skip senza Chrome, opt-in JS_SYSTEM_SPECS=1).
RSpec.describe "Filtri performance — spiegazione delle voci (CYRA-343)", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }

  let(:admin) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  it "aperto il filtro Tipo di problema, ogni voce mostra sotto una riga che la spiega" do
    sign_in_as(admin)
    # Filtro subtype attivo nei params → il select è reso visibile (non nascosto dietro il menu Filtri).
    visit member_monitoring_metric_groups_path(subtype: [ "n_plus_one" ])
    expect(page).to have_css("[data-test='metric-groups-table']")

    combo = find("select[data-test='filter-subtype']", visible: :all).find(:xpath, "..")
    combo.find("button[aria-haspopup='listbox']").click

    within combo do
      expect(page).to have_css("[role='option']", text: I18n.t("member.metrics.subtype.n_plus_one"))
      # La riga di spiegazione «in parole semplici» è visibile sotto la voce.
      expect(page).to have_text(I18n.t("member.metrics.subtype_hint.n_plus_one"))
      expect(page).to have_text(I18n.t("member.metrics.subtype_hint.rebuild_storm"))
    end
  end
end
