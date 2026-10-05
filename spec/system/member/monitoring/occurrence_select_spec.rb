# frozen_string_literal: true

require "rails_helper"

# CYRA-747 — la selezione dell'occorrenza (click, frecce, j/k, roving tabindex, annuncio) esisteva in
# due copie: una per la scheda di un gruppo errori, una per quella di un gruppo metriche. Ora il
# comportamento è UNO SOLO e le due pagine dichiarano soltanto il colore della riga scelta, quindi
# entrambe vanno provate qui: se il controller unico regredisce, una delle due smette di rispondere.
RSpec.describe "Member — selezione dell'occorrenza", type: :system, js: true do
  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  # I pannelli non scelti portano la classe `hidden`. La prova guarda LA CLASSE, non la visibilità
  # vera: il foglio di stile compilato non c'è nell'ambiente di prova, quindi per il browser
  # `hidden` non nasconde nulla e ogni pannello risulterebbe visibile.
  def expect_panel_shown(id)
    expect(page).to have_css("[data-panel-id='#{id}']:not(.hidden)", visible: :all, wait: 8)
    expect(page).to have_no_css("[data-panel-id='#{id}'].hidden", visible: :all, wait: 8)
  end

  def expect_panel_hidden(id)
    expect(page).to have_css("[data-panel-id='#{id}'].hidden", visible: :all, wait: 8)
    expect(page).to have_no_css("[data-panel-id='#{id}']:not(.hidden)", visible: :all, wait: 8)
  end

  def selected_row_ids
    page.all("[data-test='occurrence-row'][aria-selected='true']", visible: :all).map { |row| row["data-occurrence-id"] }
  end

  context "sulla scheda di un gruppo errori" do
    let(:group) { create(:error_group, project:, title: "RuntimeError: boom") }
    let!(:recente) { create(:error_event, group:, project:, occurred_at: 1.minute.ago) }
    let!(:vecchia) { create(:error_event, group:, project:, occurred_at: 10.minutes.ago) }

    before do
      sign_in_as(owner)
      visit member_monitoring_error_group_path(group)
      expect(page).to have_css("[data-test='occurrence-row']", count: 2, wait: 8)
    end

    it "premendo una riga si aprono i pannelli di quell'occorrenza" do
      expect_panel_shown(recente.id)

      page.all("[data-test='occurrence-row']").last.click

      expect_panel_shown(vecchia.id)
      expect_panel_hidden(recente.id)
      expect(selected_row_ids).to eq([ vecchia.id ])
    end

    it "le frecce e j/k spostano la selezione senza ricaricare la pagina" do
      page.all("[data-test='occurrence-row']").first.send_keys("j")

      expect_panel_shown(vecchia.id)
      expect(selected_row_ids).to eq([ vecchia.id ])

      page.all("[data-test='occurrence-row']").last.send_keys("k")

      expect_panel_shown(recente.id)
      expect(selected_row_ids).to eq([ recente.id ])
    end

    it "annuncia a chi legge con la voce l'occorrenza aperta" do
      # Al primo caricamento la zona d'annuncio tace (la selezione non l'ha scelta nessuno); parla
      # solo quando la selezione cambia per mano di chi guarda.
      annuncio = "[data-occurrence-select-target='status']"
      expect(page.find(annuncio, visible: :all).text(:all)).to eq("")

      page.all("[data-test='occurrence-row']").first.send_keys("j")

      expect(page.find(annuncio, visible: :all).text(:all)).to be_present
    end
  end

  context "sulla scheda di un gruppo metriche" do
    let(:group) { create(:metric_group, project:, title: "SELECT * FROM line_items WHERE order_id = ?") }
    let!(:recente) { create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, duration_ms: 1200) }
    let!(:vecchia) { create(:metric_sample, group:, project:, occurred_at: 10.minutes.ago, duration_ms: 900) }

    before do
      sign_in_as(owner)
      visit member_monitoring_metric_group_path(group)
      expect(page).to have_css("[data-test='occurrence-row']", count: 2, wait: 8)
    end

    it "premendo una riga si apre il pannello di quel campione" do
      expect_panel_shown(recente.id)

      page.all("[data-test='occurrence-row']").last.click

      expect_panel_shown(vecchia.id)
      expect_panel_hidden(recente.id)
      expect(selected_row_ids).to eq([ vecchia.id ])
    end

    it "risponde alle frecce come la scheda degli errori (la scorciatoia era già promessa nell'aiuto)" do
      page.all("[data-test='occurrence-row']").first.send_keys(:arrow_down)

      expect_panel_shown(vecchia.id)
      expect(selected_row_ids).to eq([ vecchia.id ])
    end
  end
end
