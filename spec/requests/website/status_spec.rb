# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Website::Status", type: :request do
  let(:org) { create(:organization, slug: "acme") }
  let(:project) do
    create(:project, organization: org, key: "MYAP", name: "My App").tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) do
    create(:environment, organization: org, code: "production", label: "Production").tap { |e| project.environments << e }
  end

  def published_monitor(**attrs)
    create(:uptime_monitor, project:, environment:, public_status_enabled: true, **attrs)
  end

  def path_for(slug: org.slug, key: project.key, code: environment.code)
    public_status_path(slug, key, code)
  end

  describe "GET /status/:org_slug/:project_key/:environment_code" do
    it "monitor pubblicato → 200, senza login, con nome progetto, environment e SLA" do
      m = published_monitor(current_status: :up)
      create(:uptime_check, monitor: m, up: true, checked_at: 5.minutes.ago)
      create(:uptime_check, monitor: m, up: true, checked_at: 4.minutes.ago)

      get path_for
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("My App")
      expect(response.body).to include("Production")
      expect(response.body).to include("100%") # 2/2 up nella finestra
      expect(response.body).to include('data-test="public-status"')
      expect(response.body).to include('data-test="uptime-timeline"')
      expect(response.body).to include('data-test="sla-summary"')
      expect(response.body).to include('<main id="main-content"') # skip-link target (a11y)
    end

    it "monitor NON pubblicato → 404 (opt-in: spento di default)" do
      published_monitor(public_status_enabled: false)
      get path_for
      expect(response).to have_http_status(:not_found)
    end

    it "org slug inesistente → 404" do
      published_monitor
      get path_for(slug: "nope")
      expect(response).to have_http_status(:not_found)
    end

    it "project key inesistente → 404" do
      published_monitor
      get path_for(key: "ZZZZ")
      expect(response).to have_http_status(:not_found)
    end

    it "environment code inesistente → 404" do
      published_monitor
      get path_for(code: "staging")
      expect(response).to have_http_status(:not_found)
    end

    it "cross-tenant: slug di un'altra org con la key di questo progetto → 404" do
      published_monitor
      other = create(:organization, slug: "other")
      get path_for(slug: other.slug) # la key MYAP non esiste nell'org "other"
      expect(response).to have_http_status(:not_found)
    end

    it "non espone dati interni: url del monitor né config (method/interval/timeout)" do
      published_monitor(url: "https://secret-internal.test/healthz", interval_seconds: 137, current_status: :up)
      get path_for
      expect(response.body).not_to include("secret-internal.test")
      # Sul TESTO della pagina, non sul body raw: i digest esadecimali degli asset
      # (es. tailwind-7631374d.css) possono contenere per caso la tripla "137".
      expect(Nokogiri::HTML(response.body).text).not_to include("137")
    end

    it "stato onesto: un monitor in pausa NON viene mostrato come operational" do
      published_monitor(active: false, current_status: :up)
      get path_for
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-state="paused"')
      expect(response.body).not_to include('data-state="operational"')
    end

    it "mostra lo storico incidenti (banner incidente in corso + risolti)" do
      m = published_monitor(current_status: :down)
      create(:uptime_incident, :resolved, monitor: m, started_at: 2.days.ago, resolved_at: 2.days.ago + 4.minutes)
      create(:uptime_incident, monitor: m, started_at: 3.minutes.ago, resolved_at: nil) # in corso
      get path_for
      expect(response.body).to include('data-test="incident-history"')
      expect(response.body).to include('data-test="open-incident"')
    end

    it "monitor nello stato unknown → data-state=unknown (mai controllato)" do
      published_monitor(current_status: :unknown, last_checked_at: nil)
      get path_for
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-state="unknown"')
    end

    it "dato vecchio (worker fermo): data-state=unknown, non operational (CYRA-209)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        published_monitor(current_status: :up, last_checked_at: 1.hour.ago)
        get path_for
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('data-state="unknown"')
        expect(response.body).not_to include('data-state="operational"')
      end
    end

    it "monitor in pausa CON incidente aperto → resta data-state=paused (pausa ha precedenza)" do
      m = published_monitor(active: false, current_status: :down)
      create(:uptime_incident, monitor: m, started_at: 3.minutes.ago, resolved_at: nil)
      get path_for
      expect(response.body).to include('data-state="paused"')
      expect(response.body).to include('data-test="open-incident"')
    end

    it "?range invalido → fallback al default, pagina comunque 200" do
      published_monitor(current_status: :up)
      get path_for, params: { range: "invalid-9x" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="uptime-timeline"')
    end

    it "?range valido (7d) → 200 usando quel range" do
      published_monitor(current_status: :up)
      get path_for, params: { range: "7d" }
      expect(response).to have_http_status(:ok)
    end

    it "la timeline non veicola lo stato solo col colore: striscia aria-hidden + riassunto sr-only" do
      m = published_monitor(current_status: :up)
      create(:uptime_check, monitor: m, up: true, checked_at: 5.minutes.ago)
      get path_for

      doc = Nokogiri::HTML(response.body)
      strip = doc.at_css('[data-test="uptime-timeline"] .flex.items-stretch')
      expect(strip["aria-hidden"]).to eq("true")
      summary = doc.at_css('[data-test="uptime-timeline-summary"]')
      expect(summary).to be_present
      expect(summary["class"]).to include("sr-only")
      expect(summary.text).to be_present
    end

    describe "?locale=it" do
      def partial_monitor
        m = published_monitor(current_status: :up)
        create(:uptime_check, monitor: m, up: true, checked_at: 5.minutes.ago)
        create(:uptime_check, monitor: m, up: true, checked_at: 4.minutes.ago)
        create(:uptime_check, monitor: m, up: false, checked_at: 3.minutes.ago)
        m
      end

      it "un solo blocco parziale → «1 parziale», al singolare" do
        partial_monitor
        get path_for, params: { range: "24h", locale: "it" }
        summary = Nokogiri::HTML(response.body).at_css('[data-test="uptime-timeline-summary"]').text
        expect(summary).to include("1 parziale,")
        expect(summary).not_to include("1 parziali")
      end

      it "la percentuale SLA usa la virgola decimale: 66,67%" do
        partial_monitor
        get path_for, params: { locale: "it" }
        sla = Nokogiri::HTML(response.body).at_css('[data-test="sla-summary"]').text
        expect(sla).to include("66,67%")
        expect(sla).not_to include("66.67%")
      end

      it "la scheda annuale dice «1a · SLA» come la card sopra, non «1y»" do
        published_monitor(current_status: :up)
        get path_for, params: { locale: "it" }
        tab = Nokogiri::HTML(response.body).at_css('[data-test="range-1y"]').text
        expect(tab).to eq("1a · SLA")
      end
    end

    describe "in inglese" do
      it "un solo blocco parziale → «1 partial»; SLA col punto decimale" do
        m = published_monitor(current_status: :up)
        create(:uptime_check, monitor: m, up: true, checked_at: 5.minutes.ago)
        create(:uptime_check, monitor: m, up: true, checked_at: 4.minutes.ago)
        create(:uptime_check, monitor: m, up: false, checked_at: 3.minutes.ago)
        get path_for, params: { range: "24h", locale: "en" }
        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css('[data-test="uptime-timeline-summary"]').text).to include("1 partial,")
        expect(doc.at_css('[data-test="sla-summary"]').text).to include("66.67%")
        expect(doc.at_css('[data-test="range-1y"]').text).to eq("1y · SLA")
      end
    end

    it "org/progetto/environment validi ma SENZA monitor → 404 (find_by nil)" do
      environment # crea org + progetto + environment, ma NESSUN monitor
      get path_for
      expect(response).to have_http_status(:not_found)
    end

    it "URL case-insensitive: key/slug/code in case diverso risolvono comunque (controller normalizza)" do
      published_monitor(current_status: :up)
      get "/status/#{org.slug.upcase}/#{project.key.downcase}/#{environment.code.upcase}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("My App")
    end

    describe "banner (announcement)" do
      it "banner attivo → mostrato col messaggio" do
        m = published_monitor(current_status: :up)
        create(:uptime_announcement, monitor: m, level: :maintenance, message: "Manutenzione notturna")
        get path_for
        expect(response.body).to include('data-test="status-announcement"')
        expect(response.body).to include("Manutenzione notturna")
      end

      it "banner scaduto (fuori finestra) → non mostrato" do
        m = published_monitor(current_status: :up)
        create(:uptime_announcement, :expired, monitor: m, message: "Vecchio avviso")
        get path_for
        expect(response.body).not_to include('data-test="status-announcement"')
        expect(response.body).not_to include("Vecchio avviso")
      end

      it "banner spento → non mostrato" do
        m = published_monitor(current_status: :up)
        create(:uptime_announcement, :inactive, monitor: m, message: "Spento")
        get path_for
        expect(response.body).not_to include('data-test="status-announcement"')
      end
    end

    describe "timeline incident narrati" do
      it "incident narrato → badge phase + step con testo pubblici" do
        m = published_monitor(current_status: :down)
        inc = create(:uptime_incident, monitor: m, phase: :monitoring, started_at: 20.minutes.ago, resolved_at: nil)
        create(:uptime_incident_update, incident: inc, phase: :detected, body: "Rilevato problema esterno")
        create(:uptime_incident_update, incident: inc, phase: :monitoring, body: "Applicata correzione, monitoriamo")
        get path_for
        expect(response.body).to include('data-test="incident-timeline"')
        expect(response.body).to include("Rilevato problema esterno")
        expect(response.body).to include("Applicata correzione, monitoriamo")
        expect(response.body).to include(I18n.t("member.uptime.incident.phases.monitoring"))
      end

      it "gli incident raggruppati collassano: solo i top-level compaiono come righe" do
        m = published_monitor(current_status: :down)
        primary = create(:uptime_incident, monitor: m, started_at: 2.hours.ago, resolved_at: 1.hour.ago)
        create(:uptime_incident, monitor: m, parent: primary, started_at: 90.minutes.ago, resolved_at: 80.minutes.ago)
        create(:uptime_incident, monitor: m, started_at: 10.minutes.ago, resolved_at: nil) # separato
        get path_for
        # 2 righe: il primary (che ingloba il figlio) + l'incident separato. Il figlio NON è una riga.
        expect(response.body.scan('data-test="incident-row"').size).to eq(2)
      end
    end

    # CYRA-715 — i due divieti vanno tolti INSIEME: `frame-ancestors 'self'` della policy dice la
    # stessa cosa di X-Frame-Options e i browser moderni le danno la precedenza, quindi toglierne uno
    # solo lascerebbe l'embed rotto con questa prova ancora verde.
    it "è incorporabile in un sito di terzi: nessun divieto di incorniciamento sulla risposta" do
      published_monitor(current_status: :up)
      get path_for
      expect(response).to have_http_status(:ok)
      expect(response.headers).not_to have_key("X-Frame-Options")
      expect(csp_of(response)).not_to include("frame-ancestors")
    end
  end

  describe "GET /status/:org_slug/:project_key/:environment_code/badge" do
    def badge_path_for(slug: org.slug, key: project.key, code: environment.code)
      public_status_badge_path(slug, key, code)
    end

    it "monitor pubblicato → 200 col badge, lo stato scritto e il link alla pagina completa" do
      published_monitor(current_status: :up)

      get badge_path_for
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="status-badge"')
      expect(response.body).to include('data-state="operational"')
      expect(response.body).to include(I18n.t("website.status.headline.operational"))
      expect(response.body).to include(public_status_url(org.slug, project.key, environment.code))
    end

    it "è incorporabile in un sito di terzi e non viene messo in cache" do
      published_monitor(current_status: :up)
      get badge_path_for
      expect(response.headers).not_to have_key("X-Frame-Options")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "il clic apre una scheda nuova, non si porta via la pagina che ospita il badge" do
      published_monitor(current_status: :up)
      get badge_path_for

      link = Nokogiri::HTML(response.body).at_css("[data-test='status-badge']")
      expect(link["target"]).to eq("_blank")
      expect(link["rel"]).to eq("noopener")
    end

    it "è autoconsistente: nessun asset esterno né foglio di stile dell'applicazione" do
      published_monitor(current_status: :up)
      get badge_path_for

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("link[rel='stylesheet']")).to be_empty
      expect(doc.css("script")).to be_empty
      expect(response.body).not_to include("fonts.googleapis.com")
      expect(response.body).not_to include("cdnjs.cloudflare.com")
    end

    it "non è indicizzabile (vive dentro il sito di qualcun altro)" do
      published_monitor(current_status: :up)
      get badge_path_for
      expect(response.body).to include('<meta name="robots" content="noindex">')
    end

    it "stato onesto: monitor in pausa → paused, mai operational" do
      published_monitor(active: false, current_status: :up)
      get badge_path_for
      expect(response.body).to include('data-state="paused"')
      expect(response.body).not_to include('data-state="operational"')
    end

    it "dato vecchio (worker fermo) → unknown, non operational (CYRA-209)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        published_monitor(current_status: :up, last_checked_at: 1.hour.ago)
        get badge_path_for
        expect(response.body).to include('data-state="unknown"')
        expect(response.body).not_to include('data-state="operational"')
      end
    end

    it "?locale=it → badge in italiano, col locale propagato al link della pagina completa" do
      published_monitor(current_status: :up)
      get badge_path_for, params: { locale: "it" }
      expect(response.body).to include(I18n.t("website.status.headline.operational", locale: :it))
      expect(response.body).to include("locale=it")
    end

    it "monitor NON pubblicato → 404 (stesso gate opt-in della pagina)" do
      published_monitor(public_status_enabled: false)
      get badge_path_for
      expect(response).to have_http_status(:not_found)
    end

    it "org slug inesistente → 404" do
      published_monitor
      get badge_path_for(slug: "nope")
      expect(response).to have_http_status(:not_found)
    end

    it "project key inesistente → 404" do
      published_monitor
      get badge_path_for(key: "ZZZZ")
      expect(response).to have_http_status(:not_found)
    end

    it "environment code inesistente → 404" do
      published_monitor
      get badge_path_for(code: "staging")
      expect(response).to have_http_status(:not_found)
    end

    it "non espone dati interni: url del monitor assente dal badge" do
      published_monitor(url: "https://secret-internal.test/healthz", current_status: :up)
      get badge_path_for
      expect(response.body).not_to include("secret-internal.test")
    end
  end
end
