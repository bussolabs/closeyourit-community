# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Analytics", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  # Progetto che RACCOGLIE analytics: piattaforma web (capable) + toggle "Raccogli analytics" attivo (opt-in).
  let(:project) { create(:project, organization: org, analytics_enabled: true).tap { |p| p.platforms << web } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET show" do
    it "non autenticato → redirect login" do
      get member_monitoring_analytics_path
      expect(response).to redirect_to(login_path)
    end

    it "owner con progetto web → 200 con i conteggi del range" do
      create(:pageview, project:, path: "/pricing")
      sign_in(owner)

      get member_monitoring_analytics_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"analytics-counts\"")
      expect(response.body).to include("/pricing")
    end

    # CYRA-570 — cinquantasei barrette al sei per cento sopra il riquadro che dichiarava il periodo
    # vuoto: due messaggi opposti nella stessa schermata. Adesso lo dice anche il grafico.
    it "senza visite nel periodo il grafico lo dichiara, invece di disegnare barre a zero" do
      create(:pageview, project:, occurred_at: 20.days.ago, path: "/vecchia")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)

      expect(response.body).to include('data-test="analytics-buckets-empty"')
      expect(response.body).to include(I18n.t("member.monitoring.analytics.chart_empty"))
      expect(response.body).not_to include('data-test="analytics-buckets"')
    end

    it "mostra il pannello Device & screen e la colonna UTM term/content" do
      create(:pageview, project:, device_type: "mobile", screen_class: "mobile", utm_term: "scarpe", utm_content: "banner-a")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)
      expect(response.body).to include("data-test=\"analytics-device-types\"")
      expect(response.body).to include("data-test=\"analytics-device-type-row\"")
      expect(response.body).to include("data-test=\"analytics-utm-term-row\"")
      expect(response.body).to include("data-test=\"analytics-utm-content-row\"")
    end

    it "senza visite da link di campagna dice una volta sola che non ce ne sono, non cinque" do
      create(:pageview, project:, path: "/pricing")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)

      utm = Nokogiri::HTML(response.body).at_css('[data-test="analytics-utm"]')
      expect(utm.text).to include(I18n.t("member.monitoring.analytics.utm_empty"))
      expect(utm.text).not_to include(I18n.t("member.monitoring.analytics.no_data"))
    end

    it "mostra il pannello Locations con i paesi risolti" do
      create(:pageview, project:, country_code: "IT")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)
      expect(response.body).to include("data-test=\"analytics-locations\"")
      expect(response.body).to include("data-test=\"analytics-country-row\"")
      expect(response.body).to include("IT")
    end

    # CYRA-503 — condividere la dashboard era l'ultima cosa della pagina, dopo quattordici riquadri
    # che nella configurazione predefinita sono vuoti: chi apriva la pagina aveva smesso di scorrere
    # molto prima. L'azione sale nella toolbar, accanto al periodo; in fondo resta l'elenco.
    context "condivisione ed embed pubblico" do
      it "senza link attivo: l'azione sta in cima e in fondo non c'è nessun pannello" do
        create(:pageview, project:)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response.body).to include("data-test=\"analytics-share-create\"")
        expect(response.body.index("analytics-share-create")).to be < response.body.index("analytics-realtime")
        expect(response.body).not_to include("data-test=\"analytics-share\"")
      end

      it "con link attivo: in fondo l'elenco (URL, embed, revoca) e in cima il rimando, non un secondo Crea link" do
        create(:pageview, project:)
        link = create(:analytics_link, project:)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response.body).to include("data-test=\"analytics-share\"")
        expect(response.body).to include("data-test=\"analytics-share-url\"")
        expect(response.body).to include("data-test=\"analytics-share-revoke\"")
        expect(response.body).to include(share_analytics_url(link.slug))
        expect(response.body).to include("data-test=\"analytics-share-open\"")
        expect(response.body).not_to include("data-test=\"analytics-share-create\"")
      end

      it "sito mai collegato: l'azione resta raggiungibile sopra la schermata di collegamento" do
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response.body).to include("data-test=\"analytics-onboarding\"")
        expect(response.body).to include("data-test=\"analytics-share-create\"")
      end

      it "sito mai collegato con link già creato: l'elenco compare comunque" do
        create(:analytics_link, project:)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response.body).to include("data-test=\"analytics-onboarding\"")
        expect(response.body).to include("data-test=\"analytics-share-url\"")
        expect(response.body).to include("data-test=\"analytics-share-open\"")
      end

      it "periodo senza dati: l'azione resta raggiungibile" do
        create(:pageview, project:, occurred_at: 20.days.ago)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response.body).to include("data-test=\"analytics-range-empty\"")
        expect(response.body).to include("data-test=\"analytics-share-create\"")
      end
    end

    it "mostra il pannello Goals con le conversioni del goal" do
      create(:analytics_goal, project:, path_pattern: "/pricing", display_name: "Visita pricing")
      create(:pageview, project:, path: "/pricing", name: "pageview")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)
      expect(response.body).to include("data-test=\"analytics-goals\"")
      expect(response.body).to include("data-test=\"analytics-goal-row\"")
      expect(response.body).to include("Visita pricing")
    end

    # CYRA-924 — the goals panel sorts on its columns (C9), with its own param.
    it "sorts the goals panel by conversions" do
      create(:analytics_goal, project:, path_pattern: "/pricing", display_name: "Visita pricing")
      create(:analytics_goal, project:, path_pattern: "/signup", display_name: "Apri signup")
      create(:pageview, project:, path: "/signup", name: "pageview")
      sign_in(owner)

      # Conversions are one query per goal (Analytics::Query#conversions): known, not this test's subject.
      allow_n_plus_one { get member_monitoring_analytics_path(project_id: project.id, goals_sort: "-total") }
      expect(response.body.index("Apri signup")).to be < response.body.index("Visita pricing")
      %w[goal unique total rate].each { |key| expect(response.body).to include("goals_sort=#{key}").or include("goals_sort=-#{key}") }
    end

    it "mostra chip sessione (durata/views), pannelli Channels ed Entry/Exit, e il confronto periodo" do
      t = Time.current
      create(:pageview, project:, path: "/landing", visitor_hash: "s1", occurred_at: t - 20.minutes, referrer_host: "www.google.com")
      create(:pageview, project:, path: "/exit", visitor_hash: "s1", occurred_at: t - 15.minutes)
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)
      expect(response.body).to include("data-test=\"analytics-count-duration\"")
      expect(response.body).to include("data-test=\"analytics-count-vpv\"")
      expect(response.body).to include("data-test=\"analytics-channels\"")
      expect(response.body).to include("data-test=\"analytics-channel-row\"")
      expect(response.body).to include("data-test=\"analytics-entry-exit\"")
      expect(response.body).to include("data-test=\"analytics-entry-row\"")
    end

    it "mostra il blocco realtime inline + sottoscrizione cable per il page-refresh Turbo" do
      create(:pageview, project:)
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)
      expect(response.body).to include("data-test=\"analytics-realtime\"")
      expect(response.body).to include("data-test=\"analytics-realtime-count\"")
      # cable: sottoscrizione allo stream analytics del progetto + opt-in al morph page-refresh
      expect(response.body).to include("turbo-cable-stream-source")
      expect(response.body).to include("turbo-refresh-method")
    end

    it "filtro click-to-filter: badge attivo e dati ristretti al valore" do
      create(:pageview, project:, browser: "Chrome", path: "/chrome-page")
      create(:pageview, project:, browser: "Firefox", path: "/firefox-page")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id, browser: "Chrome")
      expect(response.body).to include("data-test=\"analytics-active-filters\"")
      expect(response.body).to include("/chrome-page")
      expect(response.body).not_to include("/firefox-page")
    end

    it "filtro fuori allowlist ignorato (nessun badge, conta tutto)" do
      create(:pageview, project:, path: "/x")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id, visitor_hash: "hack")
      expect(response.body).not_to include("data-test=\"analytics-active-filters\"")
    end

    it "filtra per environment (default production)" do
      create(:pageview, project:, path: "/solo-staging", environment: "staging")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)
      expect(response.body).not_to include("/solo-staging")

      get member_monitoring_analytics_path(project_id: project.id, environment: "staging")
      expect(response.body).to include("/solo-staging")
    end

    it "range non valido → fallback al default (nessun 500)" do
      sign_in(owner)
      get member_monitoring_analytics_path(project_id: project.id, range: "hackerz")
      expect(response).to have_http_status(:ok)
    end

    # CYRA-449 — «Nessun dato nel periodo» copriva due situazioni opposte (mai collegato / periodo
    # sbagliato) e chi arrivava la prima volta concludeva che la funzione fosse rotta.
    context "quando il progetto non ha mai ricevuto una visita" do
      it "mostra la schermata di collegamento con snippet, copia, dominio atteso e attesa" do
        project.update!(allowed_origins: [ "https://www.esempio.it" ])
        create(:project_token, project:, public_key: "a" * 32)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("data-test=\"analytics-onboarding\"")
        expect(response.body).to include("data-test=\"analytics-onboarding-copy\"")
        expect(response.body).to include("trackPageviews: true")
        expect(response.body).to include("a" * 32)
        expect(response.body).to include("https://www.esempio.it")
        expect(response.body).to include("data-test=\"analytics-onboarding-waiting\"")
      end

      # CYRA-542 — senza versione nell'indirizzo, ogni pubblicazione dello script arrivava da sola su
      # tutti i siti già collegati e non si poteva richiamare: la versione la sceglie chi incolla.
      it "il codice da incollare dichiara la versione dello script" do
        create(:project_token, project:, public_key: "a" * 32)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)

        expect(response.body).to include("@bussolabs/closeyourit-js@0/dist/closeyourit.min.js")
        expect(response.body).not_to include("@bussolabs/closeyourit-js/dist")
      end

      # La chiave pubblica è una credenziale di ingest e la sua pagina sta dietro tokens.manage:
      # le statistiche si leggono con la sola visibilità del progetto, quindi qui va nascosta.
      it "a chi non gestisce i codici non mostra la chiave pubblica del progetto" do
        create(:project_token, project:, public_key: "b" * 32)
        create(:project_membership, account: member, project:)
        sign_in(member)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("data-test=\"analytics-onboarding\"")
        expect(response.body).not_to include("b" * 32)
        expect(response.body).to include("data-test=\"analytics-onboarding-token-locked\"")
        expect(response.body).not_to include(member_project_tokens_path(project))
      end

      it "senza token mostra il segnaposto della chiave e il link ai codici del progetto" do
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response.body).to include(I18n.t("member.monitoring.analytics.onboarding.key_placeholder"))
        expect(response.body).to include("data-test=\"analytics-onboarding-token\"")
        expect(response.body).to include(member_project_tokens_path(project))
      end

      it "non stampa i riquadri della dashboard ma lascia il cambio progetto" do
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id)
        expect(response.body).not_to include("data-test=\"analytics-locations\"")
        expect(response.body).not_to include("data-test=\"analytics-realtime\"")
        expect(response.body).to include("data-test=\"analytics-toolbar\"")
        expect(response.body).not_to include("data-test=\"range-selector\"")
      end
    end

    context "quando i dati esistono ma non nel periodo scelto" do
      it "riporta la data dell'ultima visita, un periodo utile e riduce i riquadri" do
        create(:pageview, project:, occurred_at: 3.days.ago)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id, range: "24h")
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("data-test=\"analytics-range-empty\"")
        expect(response.body).to include("data-test=\"analytics-range-empty-last\"")
        expect(response.body).to include(ERB::Util.html_escape(member_monitoring_analytics_path(project_id: project.id, environment: "production", range: "7d")))
        expect(response.body).to include("data-test=\"analytics-range-empty-panels\"")
        expect(response.body).not_to include("data-test=\"analytics-locations\"")
      end

      it "con dati nel periodo lascia i riquadri al loro posto" do
        create(:pageview, project:, occurred_at: 1.hour.ago)
        sign_in(owner)

        get member_monitoring_analytics_path(project_id: project.id, range: "24h")
        expect(response.body).to include("data-test=\"analytics-pages\"")
        expect(response.body).not_to include("data-test=\"analytics-range-empty\"")
      end
    end

    it "nessun progetto analytics-capable → empty state" do
      sign_in(owner)
      get member_monitoring_analytics_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"analytics-empty\"")
    end

    it "progetto senza piattaforma web richiesto esplicitamente → 404 (non capable)" do
      plain = create(:project, organization: org)
      sign_in(owner)
      get member_monitoring_analytics_path(project_id: plain.id)
      expect(response).to have_http_status(:not_found)
    end

    it "progetto web ma toggle 'Raccogli analytics' OFF → non nel select, richiesto esplicitamente → 404" do
      off = create(:project, organization: org, analytics_enabled: false).tap { |p| p.platforms << web }
      sign_in(owner)
      get member_monitoring_analytics_path(project_id: off.id)
      expect(response).to have_http_status(:not_found)
    end

    it "toggle attivo su un progetto web → la voce Analytics è nel menu (CYRA-521)" do
      project # collecting
      sign_in(owner)
      get member_monitoring_analytics_path

      expect(response.body).to include("data-test=\"member-nav-analytics\"")
    end

    # Il vecchio indirizzo dello spazio Growth resta come redirect: chi ce l'ha nei segnalibri atterra
    # sulla pagina che cercava, non su un 404.
    it "il vecchio indirizzo dello spazio porta alla pagina" do
      project
      sign_in(owner)
      get "/member/growth"

      expect(response).to redirect_to(member_monitoring_analytics_path)
    end

    it "solo progetti non-collecting (web ma toggle OFF) → empty state e nav Analytics assente" do
      create(:project, organization: org, analytics_enabled: false).tap { |p| p.platforms << web }
      sign_in(owner)
      get member_monitoring_analytics_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"analytics-empty\"")
      expect(response.body).not_to include("data-test=\"member-nav-analytics\"")
    end

    it "BOLA: progetto di un'altra org → 404" do
      other_org = create(:organization)
      Types::InstallDefaults.call(organization: other_org)
      foreign = create(:project, organization: other_org)
      foreign.platforms << Types::Platform.find_by!(organization: other_org, code: "web")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: foreign.id)
      expect(response).to have_http_status(:not_found)
    end

    it "member senza assegnazioni → nessun progetto visibile (empty state, strict)" do
      project # creato
      sign_in(member)
      get member_monitoring_analytics_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"analytics-empty\"")
    end
  end

  # CYRA-500 — la pagina rispondeva solo «quanto», mai «come va»; fra le pagine più viste compariva
  # l'indirizzo che serve a controllare che il sito sia acceso, e il riquadro della provenienza
  # geografica restava vuoto in mezzo a riquadri pieni.
  describe "numeri onesti e comparabili" do
    before { sign_in(owner) }

    it "esclude le visite di controllo dai conti e dalle pagine più viste" do
      create(:pageview, project:, path: "/up", occurred_at: 1.hour.ago)
      create(:pageview, project:, path: "/prezzi", occurred_at: 1.hour.ago)

      get member_monitoring_analytics_path(project_id: project.id, range: "24h")

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='analytics-count-pageviews']").text).to include("1")
      expect(pagina.at_css("[data-test='analytics-pages']").text).to include("/prezzi")
      expect(pagina.at_css("[data-test='analytics-pages']").text).not_to include("/up")
    end

    it "con l'interruttore acceso le rimette nel conto" do
      create(:pageview, project:, path: "/up", occurred_at: 1.hour.ago)
      create(:pageview, project:, path: "/prezzi", occurred_at: 1.hour.ago)

      get member_monitoring_analytics_path(project_id: project.id, range: "24h", automated: "1")

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='analytics-count-pageviews']").text).to include("2")
      expect(pagina.at_css("[data-test='analytics-pages']").text).to include("/up")
    end

    it "ogni numero di testa porta la variazione sul periodo precedente" do
      create_list(:pageview, 2, project:, occurred_at: 1.hour.ago)
      create(:pageview, project:, occurred_at: 30.hours.ago)

      get member_monitoring_analytics_path(project_id: project.id, range: "24h")

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='analytics-count-pageviews-trend']").text).to include("100%")
      expect(pagina.at_css("[data-test='analytics-comparison']")).to be_present
    end

    it "senza un periodo precedente non inventa nessuna variazione" do
      create(:pageview, project:, occurred_at: 1.hour.ago)

      get member_monitoring_analytics_path(project_id: project.id, range: "24h")

      expect(Nokogiri::HTML(response.body).at_css("[data-test='analytics-count-pageviews-trend']")).to be_nil
    end

    it "il riquadro della provenienza compare solo quando il paese si conosce" do
      create(:pageview, project:, occurred_at: 1.hour.ago, country_code: nil)

      get member_monitoring_analytics_path(project_id: project.id, range: "24h")
      expect(response.body).not_to include('data-test="analytics-locations"')

      create(:pageview, project:, occurred_at: 1.hour.ago, country_code: "IT")

      get member_monitoring_analytics_path(project_id: project.id, range: "24h")
      expect(response.body).to include('data-test="analytics-locations"')
    end

    it "la didascalia del grafico dice le date vere del periodo" do
      create(:pageview, project:, occurred_at: 1.hour.ago)

      get member_monitoring_analytics_path(project_id: project.id, range: "24h")

      finestra = Nokogiri::HTML(response.body).at_css("[data-test='analytics-chart-window']").text
      expect(finestra).to match(/\d{4}/)
      expect(finestra).to include(I18n.l(Date.current, format: :day_month_year))
      expect(finestra).not_to match(/intervalli|buckets/)
    end
  end
end
