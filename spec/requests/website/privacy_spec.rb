# frozen_string_literal: true

require "rails_helper"

# CYRA-698 — il modulo di richiesta accesso raccoglie nome, email di lavoro e testo libero e li
# scrive in banca dati; l'informativa privacy non esisteva in nessuna forma: nessuna rotta, nessuna
# chiave di traduzione, nessun link nel piè di pagina.
RSpec.describe "Website::Privacy", type: :request do
  it "la pagina esiste in inglese, senza login" do
    get "/privacy"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="website-privacy"')
    expect(response.body).to include('<html lang="en"')
  end

  it "la pagina esiste in italiano" do
    get "/it/privacy"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="website-privacy"')
    expect(response.body).to include('<html lang="it"')
  end

  it "dice quali dati raccoglie e con che base giuridica" do
    get "/it/privacy"
    testo = Nokogiri::HTML(response.body).at_css("[data-test='website-privacy']").text

    expect(testo).to include(I18n.t("website.privacy.sections.collected.title", locale: :it))
    expect(testo).to include(I18n.t("website.privacy.sections.rights.title", locale: :it))
    expect(testo).to include(I18n.t("website.privacy.controller_email"))
  end

  it "il piè di pagina del sito la linka" do
    get "/it"
    footer = Nokogiri::HTML(response.body).at_css("[data-test='website-footer']")

    expect(footer.at_css("[data-test='website-footer-privacy']")["href"]).to eq("/it/privacy")
  end

  it "ha il piè di pagina del sito, con la firma, come le altre pagine pubbliche" do
    get "/it/privacy"
    footer = Nokogiri::HTML(response.body).at_css("[data-test='website-footer']")

    expect(footer).to be_present
    expect(footer.text).to include("Alessio Bussolari")
  end

  it "il modulo di richiesta accesso rimanda all'informativa prima di raccogliere i dati" do
    get "/it/richiedi-accesso"
    doc = Nokogiri::HTML(response.body)

    expect(doc.at_css("[data-test='request-access-privacy']")["href"]).to eq("/it/privacy")
  end

  it "entra nella sitemap, in entrambe le lingue" do
    get "/sitemap.xml"

    expect(response.body).to include("/privacy")
    expect(response.body).to include("/it/privacy")
  end

  it "l'area autenticata la linka" do
    org = create(:organization)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }

    get root_path
    expect(Nokogiri::HTML(response.body).at_css("[data-test='member-menu-privacy']")).to be_present
  end
end
