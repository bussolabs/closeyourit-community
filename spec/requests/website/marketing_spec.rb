# frozen_string_literal: true

require "rails_helper"

# Flussi del sito marketing pubblico: field guide → richiesta accesso, switch lingua. Sono pagine
# statiche senza JS: il percorso si prova seguendo gli indirizzi dei collegamenti resi in pagina.
RSpec.describe "Website — sito marketing", type: :request do
  def link(test_id)
    Nokogiri::HTML(response.body).at_css("[data-test='#{test_id}']")["href"]
  end

  it "guest: landing → Operational Field Guide → richiesta accesso" do
    get "/"
    expect(response.body).to include('data-test="website-home"')
    expect(response.body).to include('data-test="website-workflow"')

    get link("website-cta-access")

    expect(response.request.path).to eq("/request-access")
    expect(response.body).to include('data-test="website-access-request"')
  end

  it "switch lingua: landing EN → IT → integrations IT → ritorno alla pagina EN equivalente" do
    get "/"
    get link("website-lang-it")
    expect(response.request.path).to eq("/it")
    expect(response.body).to include('data-test="website-home"')

    get link("website-nav-integrations")
    expect(response.request.path).to eq("/it/integrazioni")
    expect(response.body).to include('data-test="website-integrations"')

    get link("website-lang-en")
    expect(response.request.path).to eq("/integrations")
    expect(response.body).to include('data-test="website-integrations"')
  end

  it "nav: brand torna alla landing, sign-in porta al login" do
    get "/integrations"
    indirizzo_login = link("website-nav-signin")

    get link("website-brand")
    expect(response.body).to include('data-test="website-home"')

    expect(indirizzo_login).to eq(login_path)
  end
end
