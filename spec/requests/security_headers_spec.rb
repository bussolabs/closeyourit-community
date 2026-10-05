# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Security headers", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def enforced_csp
    response.headers["Content-Security-Policy"]
  end

  def reported_csp
    response.headers["Content-Security-Policy-Report-Only"]
  end

  # L'header attivo, qualunque sia il canale: le direttive di base valgono per tutti e due i modi.
  def csp
    csp_of(response)
  end

  def external_stylesheet_hosts(body)
    Nokogiri::HTML(body)
      .css('link[rel="stylesheet"]')
      .filter_map { |link| link["href"] }
      .select { |href| href.start_with?("http") }
      .map { |href| URI.parse(href).host }
      .uniq
  end

  it "la CSP dichiara le direttive di base" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect(csp).to include("default-src 'self'")
    expect(csp).to include("object-src 'none'")
    expect(csp).to include("base-uri 'self'")
  end

  it "la CSP dichiara un endpoint di raccolta delle violazioni (report-uri)" do
    get login_path

    expect(csp).to include("report-uri /csp-reports")
  end

  # CYRA-715: la policy era in report-only su TUTTI i canali. Un browser che segnala e basta non
  # protegge nessuno: uno script iniettato in una pagina dell'area utenti veniva eseguito lo stesso.
  describe "l'area autenticata è in enforce, non in sola segnalazione" do
    before { create(:membership, account: owner, organization: org, role: :owner) }

    it "una pagina dell'area utenti emette la CSP che BLOCCA" do
      sign_in(owner)

      get member_tickets_path

      expect(response).to have_http_status(:ok)
      expect(enforced_csp).to be_present
      expect(reported_csp).to be_nil
    end

    it "la pagina di accesso emette la CSP che blocca" do
      get login_path

      expect(enforced_csp).to be_present
      expect(reported_csp).to be_nil
    end

    it "il pannello god emette la CSP che blocca" do
      sign_in_god(create(:account, god: true))

      get valhalla_root_path

      expect(response).to have_http_status(:ok)
      expect(enforced_csp).to be_present
      expect(reported_csp).to be_nil
    end
  end

  # Il canale pubblico resta in raccolta: le sue pagine sono incollate e incorniciate in casa d'altri
  # (badge, status page, dashboard condivisa) e nessuno se ne accorgerebbe se un blocco le rovinasse.
  # Le violazioni continuano ad arrivare al report-uri, che è il modo per deciderlo con i dati.
  describe "il sito pubblico resta in sola segnalazione" do
    it "la home marketing emette la CSP in sola segnalazione" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(reported_csp).to be_present
      expect(enforced_csp).to be_nil
    end
  end

  # CYRA-715: il codice che autorizza gli script nostri era l'id di sessione — uguale per settimane e
  # VUOTO sulle pagine pubbliche, dove la sessione non esiste ancora. Un valore che non cambia si
  # riusa: chi lo legge una volta può firmare i propri script per tutta la sessione.
  describe "il codice che autorizza gli script" do
    it "cambia a ogni pagina" do
      get login_path
      primo = csp_nonce_in(csp)

      get login_path
      secondo = csp_nonce_in(csp)

      expect(primo).to be_present
      expect(secondo).to be_present
      expect(secondo).not_to eq(primo)
    end

    # Era l'id di sessione: sulle pagine pubbliche la sessione non è ancora nata, l'id è vuoto e la
    # policy usciva con `'nonce-'` — una firma vuota, che non autorizza e non protegge niente.
    it "non è mai vuoto, nemmeno dove la sessione non esiste ancora" do
      get "/"

      expect(csp).to include("script-src")
      expect(csp_nonce_in(csp).to_s.length).to be >= 16
    end

    it "è lo stesso che l'HTML dichiara agli script della pagina" do
      get login_path

      html = Nokogiri::HTML(response.body)
      meta = html.at_css('meta[name="csp-nonce"]')&.[]("content")
      importmap = html.at_css('script[type="importmap"]')&.[]("nonce")

      expect(csp_nonce_in(csp)).to be_present
      expect(meta).to eq(csp_nonce_in(csp))
      expect(importmap).to eq(csp_nonce_in(csp))
    end
  end

  # La policy attiva nel browser è quella del PRIMO documento caricato: Turbo, navigando, non la
  # sostituisce. Chi entrava dal sito pubblico e premeva «Accedi» si portava dietro nell'area
  # riservata la policy che segnala e basta — l'enforce c'era negli header e non nel browser, senza
  # un errore da nessuna parte. Il meta dichiara il modo ed è tracciato: due canali con valori
  # diversi fanno ricaricare Turbo al passaggio, in tutte e due le direzioni.
  describe "il confine fra i due canali" do
    before { create(:membership, account: owner, organization: org, role: :owner) }

    def csp_mode_of(body)
      Nokogiri::HTML(body).at_css('meta[name="csp-mode"]')
    end

    it "l'area riservata dichiara di bloccare, ed è un elemento che Turbo sorveglia" do
      sign_in(owner)

      get member_tickets_path

      meta = csp_mode_of(response.body)
      expect(meta).to be_present
      expect(meta["content"]).to eq("enforce")
      expect(meta["data-turbo-track"]).to eq("reload"),
        "senza data-turbo-track Turbo non ricarica al passaggio e il meta non serve a niente"
    end

    it "il sito pubblico dichiara di segnalare soltanto" do
      get "/"

      expect(csp_mode_of(response.body)["content"]).to eq("report")
    end

    it "i due valori sono diversi: è la differenza a far ricaricare" do
      get "/"
      pubblico = csp_mode_of(response.body)["content"]
      get login_path
      riservata = csp_mode_of(response.body)["content"]

      expect(riservata).not_to eq(pubblico)
    end
  end

  # Il commento di content_security_policy.rb rimandava frame-ancestors "al passaggio all'enforce":
  # ci siamo. Vale solo dove l'incorniciamento non è previsto — le pagine fatte apposta per stare in
  # un iframe altrui devono restare incorniciabili.
  describe "l'incorniciamento in pagine di terzi" do
    before { create(:membership, account: owner, organization: org, role: :owner) }

    it "l'area utenti dichiara di non essere incorniciabile da fuori" do
      sign_in(owner)

      get member_tickets_path

      expect(directive_of(enforced_csp, "frame-ancestors")).to include("'self'")
    end

    it "il badge pubblico resta incorniciabile (nessun frame-ancestors)" do
      project = create(:project, organization: org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
      end
      environment = create(:environment, organization: org).tap { |e| project.environments << e }
      create(:uptime_monitor, project:, environment:, public_status_enabled: true, current_status: :up)

      get public_status_badge_path(org.slug, project.key, environment.code)

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Frame-Options"]).to be_nil
      expect(directive_of(csp, "frame-ancestors")).to be_empty
    end

    # `request.content_security_policy` restituisce a OGNI richiesta lo stesso oggetto, quello messo
    # in `env_config` all'avvio: togliere una direttiva modificandolo in luogo la toglierebbe a tutti
    # da lì in poi — l'area utenti perderebbe la protezione perché qualcuno ha aperto un badge.
    # Passiamo da `current_content_security_policy`, che ne fa una copia; questa prova sta qui perché
    # la differenza fra le due strade è invisibile finché non si guardano due richieste di fila.
    it "una pagina incorniciabile non toglie il divieto anche a quelle dopo" do
      project = create(:project, organization: org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
      end
      environment = create(:environment, organization: org).tap { |e| project.environments << e }
      create(:uptime_monitor, project:, environment:, public_status_enabled: true, current_status: :up)
      sign_in(owner)

      get public_status_badge_path(org.slug, project.key, environment.code)
      expect(directive_of(csp, "frame-ancestors")).to be_empty

      get member_tickets_path

      expect(response).to have_http_status(:ok)
      expect(directive_of(enforced_csp, "frame-ancestors")).to include("'self'")
    end
  end

  # CYRA-238: il sito marketing self-hosta i caratteri (woff2 in app/assets/fonts). Il canale pubblico
  # non deve più chiamare fonts.googleapis.com né cdnjs: è la ragione stessa del ticket, e nessuno se
  # ne accorgerebbe se un layout tornasse a linkarli — la pagina continuerebbe a funzionare.
  describe "il sito marketing non dipende da fonti esterne" do
    before { get "/" }

    it "la home marketing risponde 200" do
      expect(response).to have_http_status(:ok)
    end

    it "la home non carica alcun foglio di stile esterno" do
      expect(external_stylesheet_hosts(response.body)).to be_empty
    end
  end

  # CYRA-926: icons are inline Lucide SVG, so the access and member layouts load no external CSS and
  # the CSP stops allowing cdnjs, which only served Font Awesome.
  describe "access pages without Font Awesome" do
    before { get login_path }

    it "load no external stylesheet" do
      expect(external_stylesheet_hosts(response.body)).to be_empty
    end

    it "no longer allow cdnjs in the CSP" do
      expect(directive_of(csp, "style-src")).not_to include("cdnjs.cloudflare.com")
      expect(directive_of(csp, "font-src")).not_to include("cdnjs.cloudflare.com")
    end
  end
end
