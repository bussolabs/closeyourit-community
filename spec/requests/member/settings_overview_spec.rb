# frozen_string_literal: true

require "rails_helper"

# CYRA-441 — la pagina d'ingresso dell'Amministrazione era un elenco nudo di voci: chi arrivava la
# prima volta non stava configurando, stava indovinando. Ogni voce porta ora la sua riga di
# spiegazione — la stessa del catalogo delle guide, mai una copia che resta indietro — e la pagina
# rimanda alla guida che spiega i contenitori (organizzazione, gruppi, progetti, ambienti, piattaforme).
RSpec.describe "Member — pagina di ingresso dell'Amministrazione", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def page = Nokogiri::HTML(response.body)

  it "ogni voce dell'area ha la sua riga di spiegazione" do
    sign_in(owner)

    get member_settings_path

    expect(response).to have_http_status(:ok)
    # CYRA-545 — «github_app» era la voce della sola GitHub App: adesso la voce dell'area è
    # «integrations», l'elenco di tutti i servizi collegabili, e GitHub è una delle sue schede.
    %w[members service_accounts teams roles platforms environments organization guidance integrations].each do |chiave|
      expect(page.text).to include(I18n.t("member.guides.catalog.#{chiave}")),
                           "manca la spiegazione della voce #{chiave}"
    end
  end

  it "ogni destinazione elencata porta la sua riga, nessuna resta nuda" do
    sign_in(owner)

    get member_settings_path

    voci = page.css('[data-test^="settings-overview-member-nav-"]')
    expect(voci).not_to be_empty
    voci.each do |voce|
      descrizione = voce.at_css('[data-test="settings-overview-description"]')
      expect(descrizione&.text).to be_present, "voce senza spiegazione: #{voce['data-test']}"
    end
  end
end
