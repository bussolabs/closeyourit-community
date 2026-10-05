# frozen_string_literal: true

require "rails_helper"

# CYRA-372 — un indirizzo inesistente rispondeva con la pagina statica di Rails: schermata bianca,
# inglese, nessun menu, nessuna uscita. Proprio a chi è già disorientato.
RSpec.describe "Pagine di errore", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before { create(:membership, account:, organization: org, role: :owner) }

  # In test Rails mostra la pagina di debug invece di passare dall'exceptions_app: qui si chiede il
  # comportamento di PRODUZIONE, che è quello che il ticket riguarda.
  around do |example|
    config = Rails.application.env_config
    original = config.values_at("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    config["action_dispatch.show_exceptions"] = :all
    config["action_dispatch.show_detailed_exceptions"] = false
    example.run
    config["action_dispatch.show_exceptions"], config["action_dispatch.show_detailed_exceptions"] = original
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  # Dentro l'area member la 404 col guscio esiste già (CYRA-462): qui si copre TUTTO IL RESTO, che
  # fino a ora rispondeva col file statico di Rails.
  it "un indirizzo inesistente fuori dall'area risponde 404 con la pagina del prodotto" do
    get "/questo-non-esiste-affatto"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include('data-test="error-page"')
    # Locale esplicita: senza sessione né header la pagina parla italiano (CYRA-554), mentre I18n.locale
    # del processo di test resta il default :en — un `t` senza locale confronterebbe l'altra lingua.
    expect(response.body).to include(I18n.t("errors.pages.not_found.title", locale: :it))
    expect(response.body).to include('data-test="error-page-home"')
  end

  it "con la sessione attiva la pagina porta il menu e una seconda via d'uscita" do
    sign_in(account)

    get "/questo-non-esiste-affatto"

    expect(response.body).to include('id="member-sidebar"')
    expect(response.body).to include('data-test="error-page-tickets"')
  end

  it "senza sessione resta un 404 con la pagina semplice, senza errori a cascata" do
    get "/questo-non-esiste-affatto"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include(I18n.t("errors.pages.not_found.title", locale: :it))
    expect(response.body).not_to include('id="member-sidebar"')
  end

  it "la pagina di errore non mostra il testo predefinito del framework" do
    get "/questo-non-esiste-affatto"

    expect(response.body).not_to include("The page you were looking for doesn't exist")
  end

  # L'indirizzo che si indovina da soli: il menu punta alla sotto-rotta, e la radice dava errore.
  it "l'indirizzo base delle attività porta alla board" do
    sign_in(account)

    get "/member/workload"

    expect(response).to redirect_to("/member/workload/actions")
  end

  # CYRA-554 — la pagina di errore parlava inglese a chi usa il prodotto in italiano: titolo, testo e
  # tutte le voci del menu. La sessione veniva ripresa DOPO la scelta della lingua, quindi la
  # preferenza dell'account non si vedeva ancora e restava il default I18n (:en).
  describe "lingua della pagina di errore" do
    it "chi usa il prodotto in italiano legge la pagina in italiano, menu compreso" do
      account.update!(locale: "it")
      sign_in(account)

      get "/questo-non-esiste-affatto"

      expect(response.body).to include('lang="it"')
      expect(response.body).to include(I18n.t("errors.pages.not_found.title", locale: :it))
      expect(response.body).to include(I18n.t("member.nav.group_observability", locale: :it))
      expect(response.body).not_to include(I18n.t("errors.pages.not_found.title", locale: :en))
    end

    it "chi usa il prodotto in inglese continua a leggerla in inglese" do
      account.update!(locale: "en")
      sign_in(account)

      get "/questo-non-esiste-affatto"

      expect(response.body).to include('lang="en"')
      expect(response.body).to include(I18n.t("errors.pages.not_found.title", locale: :en))
    end

    # Il rischio dichiarato nel ticket: la stessa pagina racconta anche il guasto interno, ed è il
    # momento peggiore per cambiare lingua sotto gli occhi di chi legge. Si arriva alla 500 solo
    # rompendo davvero una pagina: l'indirizzo /500 lo servirebbe il file statico di public/, non
    # l'applicazione (ActionDispatch::Static precede il router).
    it "anche il guasto interno è raccontato nella lingua della persona" do
      account.update!(locale: "it")
      sign_in(account)
      allow_any_instance_of(HomeController).to receive(:index).and_raise("guasto simulato")

      get "/"

      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).to include('lang="it"')
      expect(response.body).to include(I18n.t("errors.pages.internal_server_error.title", locale: :it))
    end

    it "senza sessione vale la lingua dichiarata dal browser" do
      get "/questo-non-esiste-affatto", headers: { "HTTP_ACCEPT_LANGUAGE" => "en-GB,en;q=0.9" }

      expect(response.body).to include('lang="en"')
      expect(response.body).to include(I18n.t("errors.pages.not_found.title", locale: :en))
    end

    # Nessun segnale (né sessione né browser): la pagina dell'applicazione dice le stesse parole della
    # sua controparte statica in public/, che dal CYRA-325 è in italiano.
    it "senza sessione e senza indicazione del browser resta l'italiano delle pagine di riserva" do
      get "/questo-non-esiste-affatto"

      expect(response.body).to include('lang="it"')
      expect(response.body).to include(I18n.t("errors.pages.not_found.title", locale: :it))
    end
  end

  # CYRA-554 Scenario 2 — accorciare l'indirizzo fino alla radice dell'area non è un errore di
  # digitazione: è il gesto con cui si torna indietro. Portava alla pagina "non esiste".
  describe "radice dell'area member" do
    it "l'indirizzo accorciato /member riporta alla pagina iniziale" do
      sign_in(account)

      get "/member"

      expect(response).to redirect_to("/")
    end

    it "anche da sloggato /member non risponde con la pagina di errore" do
      get "/member"

      expect(response).to redirect_to("/")
    end
  end
end
