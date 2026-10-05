# frozen_string_literal: true

require "rails_helper"

# CYRA-715 — quattro elenchi di monitoraggio aprivano la scheda con un `onclick` scritto dentro il
# `<tr>`. Ora che la Content Security Policy dell'area utenti blocca davvero, quel codice non parte
# più: la riga si illuminerebbe al passaggio del mouse e non farebbe niente, senza un errore da
# nessuna parte. Le righe passano al controller Stimulus `ui--row-link`, che vive in un file servito
# dalla nostra origine e che la policy autorizza.
#
# Qui si presidia il contratto HTML (bersaglio giusto, destinazione giusta, comandi esclusi). Che il
# clic vero apra la scheda lo prova `spec/system/member/monitoring/seo_site_show_spec.rb` col browser.
RSpec.describe "Member::Monitoring — righe di elenco cliccabili", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def row(test_id)
    Nokogiri::HTML(response.body).at_css(%([data-test="#{test_id}"]))
  end

  def site_in(target_project)
    environment = create(:environment, organization: target_project.organization)
    target_project.environments << environment
    create(:seo_site, project: target_project, environment:)
  end

  # Ogni riga: chi la governa, dove porta, e come si arriva a renderizzarla.
  def expect_row_opens(row_node, destination)
    expect(row_node).to be_present
    expect(row_node["onclick"]).to be_nil, "l'attributo onclick è codice inline: la CSP lo blocca"
    expect(row_node["data-controller"]).to include("ui--row-link")
    expect(row_node["data-action"]).to include("click->ui--row-link#open")
    expect(row_node["data-ui--row-link-url-value"]).to eq(destination)
  end

  it "la riga di uno stream log apre la voce" do
    entry = create(:log_entry, project:, message: "disk almost full")
    sign_in(owner)

    get member_monitoring_log_entries_path

    expect_row_opens(row("log-entry-row"), member_monitoring_log_entry_path(entry))
  end

  it "la riga di un rilievo SEO apre il rilievo" do
    site = site_in(project)
    page = create(:seo_page, site:, url: "#{site.base_url}/chi-siamo")
    issue = create(:seo_issue, site:, page:, check_key: "missing_h1")
    sign_in(owner)

    get member_monitoring_seo_index_path

    expect_row_opens(row("seo-row"), member_monitoring_seo_path(issue))
  end

  it "la riga di una vulnerabilità apre la scheda" do
    manifest = create(:vulnerability_manifest, project:)
    package = create(:vulnerability_package, manifest:, name: "rails", version: "7.0.0")
    finding = create(:vulnerability_finding, project:, package:, advisory: create(:vulnerability_advisory))
    sign_in(owner)

    get member_monitoring_vulnerabilities_path

    expect_row_opens(row("vulnerability-row"), member_monitoring_vulnerability_path(finding))
  end

  describe "l'elenco dei siti SEO" do
    it "la riga apre la scheda del sito" do
      site = site_in(project)
      sign_in(owner)

      get member_monitoring_seo_sites_path

      expect_row_opens(row("seo-site-row"), member_monitoring_seo_site_path(site))
    end

    # Un clic, un effetto solo: premere «Riesegui» o «Modifica» non deve anche portare via la pagina.
    # Prima lo garantiva un `onclick="event.stopPropagation()"` sulla cella, che la CSP blocca.
    it "la cella dei comandi resta esclusa dall'apertura della riga" do
      site_in(project)
      sign_in(owner)

      get member_monitoring_seo_sites_path

      cella = Nokogiri::HTML(response.body).at_css("[data-test='seo-site-row'] [data-ui--row-link-skip]")
      expect(cella).to be_present, "senza il marcatore, premere un comando aprirebbe anche la riga"
      expect(cella.name).to eq("td")
    end
  end
end
