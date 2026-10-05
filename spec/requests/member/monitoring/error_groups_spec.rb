# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::ErrorGroups", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  # I tre attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune faceva pagare a tutti tre account e tre membership.
  let(:owner) { account_with_membership(:owner) }
  let(:admin) { account_with_membership(:admin) }
  let(:member) { account_with_membership(:member) }

  before do
    Types::InstallDefaults.call(organization: org)
  end

  def account_with_membership(role)
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: role) }
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_monitoring_error_groups_path
      expect(response).to redirect_to(login_path)
    end

    it "admin → 200 e vede i gruppi dell'org" do
      sign_in(owner)
      create(:error_group, project:, title: "RuntimeError: boom")
      get member_monitoring_error_groups_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("RuntimeError: boom")
    end

    it "member assegnato vede gli errori del progetto, non di un progetto non assegnato (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      visible = create(:error_group, project:, title: "VisibleError")
      hidden = create(:error_group, project: create(:project, organization: org), title: "HiddenError")
      get member_monitoring_error_groups_path
      expect(response.body).to include("VisibleError")
      expect(response.body).not_to include("HiddenError")
      _ = [ visible, hidden ]
    end

    it "member senza assegnazioni → nessun gruppo (strict)" do
      sign_in(member)
      create(:error_group, project:, title: "SomeError")
      get member_monitoring_error_groups_path
      expect(response.body).not_to include("SomeError")
    end

    it "filtra per status" do
      sign_in(owner)
      create(:error_group, project:, title: "OpenOne", status: :unresolved)
      create(:error_group, project:, title: "DoneOne", status: :resolved)
      get member_monitoring_error_groups_path, params: { status: [ "resolved" ] }
      expect(response.body).to include("DoneOne")
      expect(response.body).not_to include("OpenOne")
    end

    it "filtra per level" do
      sign_in(owner)
      create(:error_group, project:, title: "FatalOne", level: :fatal)
      create(:error_group, project:, title: "InfoOne", level: :info)
      get member_monitoring_error_groups_path, params: { level: [ "fatal" ] }
      expect(response.body).to include("FatalOne")
      expect(response.body).not_to include("InfoOne")
    end

    it "filtra per handled=unhandled: mostra solo i gruppi con almeno un crash non gestito" do
      sign_in(owner)
      create(:error_group, :unhandled, project:, title: "CrashOne")
      create(:error_group, project:, title: "CaughtOne")
      get member_monitoring_error_groups_path, params: { handled: [ "unhandled" ] }
      expect(response.body).to include("CrashOne")
      expect(response.body).not_to include("CaughtOne")
    end

    # CYRA-400 Scenario 2: chi ha stretto i filtri fino a non trovare niente deve poterli togliere
    # tutti insieme, non uno alla volta.
    it "quando nessun errore corrisponde ai filtri offre di toglierli tutti" do
      sign_in(owner)
      create(:error_group, project:, title: "OpenOne", status: :unresolved)

      get member_monitoring_error_groups_path, params: { q: "niente-di-niente" }

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='errors-no-match']")).to be_present
      expect(doc.at_css("[data-test='errors-clear-filters']")).to be_present
    end

    it "il comando riporta all'elenco completo, default compresi" do
      sign_in(owner)
      create(:error_group, project:, title: "DoneOne", status: :resolved)
      create(:error_group, project:, title: "StagingOne", status: :ignored)

      get member_monitoring_error_groups_path, params: { q: "niente-di-niente" }
      href = Nokogiri::HTML(response.body).at_css("[data-test='errors-clear-filters']")["href"]
      get href

      expect(response.body).to include("DoneOne", "StagingOne")
      expect(Nokogiri::HTML(response.body).at_css("[data-test='errors-no-match']")).to be_nil
    end

    it "anche filtrando per ambiente il vuoto si legge come «nessuna corrispondenza», non come «nessun errore»" do
      sign_in(owner)
      group = create(:error_group, project:, title: "OnlyProduction")
      create(:error_event, group:, project:, environment: "production")

      get member_monitoring_error_groups_path, params: { environment: [ "staging" ] }

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='errors-no-match']")).to be_present
      expect(doc.at_css("[data-test='errors-clear-filters']")).to be_present
      expect(doc.at_css("[data-test='errors-empty']")).to be_nil
    end

    it "il badge 'non gestito' compare solo sui gruppi con crash" do
      sign_in(owner)
      crash = create(:error_group, :unhandled, project:, title: "CrashOne")
      caught = create(:error_group, project:, title: "CaughtOne")
      get member_monitoring_error_groups_path
      expect(response.body).to include("error-group-unhandled-#{crash.id}")
      expect(response.body).not_to include("error-group-unhandled-#{caught.id}")
    end

    # CYRA-377: su un portatile la colonna del messaggio si prendeva oltre un terzo della riga
    # (titolo su 3-4 righe + culprit in mono non spezzabile) e spingeva fuori vista i numeri di
    # eventi/utenti/ultima occorrenza. Il messaggio va troncato (titolo 2 righe, culprit 1 riga)
    # col testo completo nel tooltip, e le colonne numeriche non devono andare a capo.
    it "tronca il messaggio e tiene i numeri su una riga, col testo intero nel tooltip (CYRA-377)" do
      sign_in(owner)
      long_title = "RuntimeError: #{'dettaglio lunghissimo del messaggio ' * 6}".strip
      long_culprit = "App::#{'VeryLongNamespaceSegment' * 5}#render"
      group = create(:error_group, project:, title: long_title, culprit: long_culprit,
                                   events_count: 2202, users_count: 555)

      get member_monitoring_error_groups_path

      doc = Nokogiri::HTML(response.body)
      row = doc.at_css("[data-test='error-group-row']")

      title_el = row.at_css("[data-test='error-group-title-#{group.id}']")
      expect(title_el["class"]).to include("line-clamp-2")
      expect(title_el["title"]).to eq(long_title)

      culprit_el = row.at_css("[data-test='error-group-culprit-#{group.id}']")
      expect(culprit_el["class"]).to include("truncate")
      expect(culprit_el["title"]).to eq(long_culprit)

      # i numeri (eventi/utenti/ultima) restano su una riga e leggibili per intero
      %w[error-group-events error-group-users error-group-last-seen].each do |cell|
        el = row.at_css("[data-test='#{cell}-#{group.id}']")
        expect(el["class"]).to include("whitespace-nowrap")
      end
      # CYRA-568: il conteggio è scritto come lo scrive la lingua, lo stesso numero della finestra
      # che apre il ticket da questo gruppo.
      expect(row.at_css("[data-test='error-group-events-#{group.id}']").text.strip).to eq("2,202")
      expect(row.at_css("[data-test='error-group-users-#{group.id}']").text.strip).to eq("555")
    end

    it "senza punto d'origine il titolo non ha sotto una riga col solo «—»" do
      sign_in(owner)
      group = create(:error_group, project:, title: "SenzaOrigine", culprit: nil)

      get member_monitoring_error_groups_path

      row = Nokogiri::HTML(response.body).at_css("[data-test='error-group-row']")
      expect(row.at_css("[data-test='error-group-culprit-#{group.id}']")).to be_nil
      expect(row.at_css("[data-test='error-group-link-#{group.id}']").text).not_to include("—")
    end

    # CYRA-380 Scenario 1: users_count 0 significa «contesto utente mai inviato», non «zero colpiti».
    # La colonna mostra «non tracciato» con link alla guida, non un trattino/zero fuorviante.
    it "colonna Utenti: «non tracciato» + link alla guida quando il contesto non è mai arrivato (CYRA-380)" do
      sign_in(owner)
      group = create(:error_group, project:, title: "UntrackedUsers", users_count: 0)
      # CYRA-883: with no tracking row at all the page says it once in the header; one tracking row
      # keeps the per-row wording this example is about.
      create(:error_group, project:, title: "TrackedUsers", users_count: 3)

      get member_monitoring_error_groups_path

      cell = Nokogiri::HTML(response.body).at_css("[data-test='error-group-users-#{group.id}']")
      expect(cell.text).to include(I18n.t("member.monitoring.users_untracked"))
      # CYRA-883: the only dash is the page-wide variant, hidden unless no row tracks users.
      expect(cell.css("span.hidden").map(&:text)).to eq([ "—" ])
      expect(cell.at_css("a")["href"]).to eq(member_guides_errors_path)
    end

    # CYRA-380 Scenario 2 + Rischi: appena il gruppo ha contato almeno un utente (anche tracciamento
    # parziale) mostra il numero reale, MAI «non tracciato».
    it "colonna Utenti: il conteggio reale quando almeno un utente è stato tracciato (CYRA-380)" do
      sign_in(owner)
      group = create(:error_group, project:, title: "TrackedUsers", users_count: 42)

      get member_monitoring_error_groups_path

      cell = Nokogiri::HTML(response.body).at_css("[data-test='error-group-users-#{group.id}']")
      expect(cell.text.strip).to eq("42")
      expect(cell.text).not_to include(I18n.t("member.monitoring.users_untracked"))
    end

    it "search per titolo/culprit" do
      sign_in(owner)
      create(:error_group, project:, title: "Searchable", culprit: "App::Foo")
      create(:error_group, project:, title: "HiddenTitle", culprit: "App::Bar")
      get member_monitoring_error_groups_path, params: { q: "Searchable" }
      expect(response.body).to include("Searchable")
      expect(response.body).not_to include("HiddenTitle")
    end

    it "filtra per project_id (filter_ids project_id[])" do
      sign_in(owner)
      other_project = create(:project, organization: org)
      create(:error_group, project:, title: "HereErr")
      create(:error_group, project: other_project, title: "ThereErr")
      get member_monitoring_error_groups_path, params: { project_id: [ project.id ] }
      expect(response.body).to include("HereErr")
      expect(response.body).not_to include("ThereErr")
    end
  end

  describe "GET show" do
    it "admin → 200 con dettagli + stacktrace dell'ultimo evento" do
      sign_in(owner)
      group = create(:error_group, project:, title: "RuntimeError: boom")
      create(:error_event, group:, project:, occurred_at: 1.minute.ago,
             stacktrace: { "frames" => [ { "filename" => "app/x.rb", "function" => "call", "in_app" => true, "lineno" => 9 } ] })
      get member_monitoring_error_group_path(group)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("RuntimeError: boom")
      expect(response.body).to include("app/x.rb")
    end

    # CYRA-566 Scenario 1 — la sequenza si fermava ai primi venti passaggi senza dirlo, e i tagliati
    # erano proprio i più esterni: quelli che dicono da dove è partita la chiamata. Ora il taglio è
    # dichiarato col numero dei nascosti e i nascosti stanno tutti dentro un blocco apribile.
    it "stack più lungo del collasso: dichiara quanti passaggi restano e li rende apribili (CYRA-566)" do
      sign_in(owner)
      group = create(:error_group, project:)
      collapsed = Monitoring::Constants::STACKTRACE_COLLAPSED
      total = collapsed + 5
      # Sentry ordina dal più esterno al punto del guasto; la vista inverte, quindi il primo frame del
      # payload («outermost») è l'ULTIMO della lista ed è il primo a sparire col taglio.
      frames = Array.new(total) { |i| { "filename" => "app/f#{i}.rb", "function" => "call", "lineno" => i } }
      frames.first["filename"] = "config/outermost.rb"
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, stacktrace: { "frames" => frames })

      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      more = doc.at_css("[data-test='frames-more']")
      expect(more).to be_present
      expect(more.at_css("summary").text).to include(
        I18n.t("member.monitoring.frames_hidden", count: total - collapsed))
      # I nascosti stanno DENTRO il blocco apribile, non sciolti nella lista: il più esterno compare qui.
      expect(more.text).to include("config/outermost.rb")
      # E la lista visibile resta ferma ai primi venti, nell'ordine di prima.
      visible = doc.css("[data-test='frames'] > [data-test='frame']")
      expect(visible.size).to eq(collapsed)
      expect(visible.first.text).to include("app/f#{total - 1}.rb")
      # Nessun passaggio perso per strada: visibili + nascosti = quelli arrivati.
      expect(doc.css("[data-test='frame']").size).to eq(total)
    end

    it "stack corto: nessun blocco dei passaggi nascosti (CYRA-566)" do
      sign_in(owner)
      group = create(:error_group, project:)
      frames = Array.new(Monitoring::Constants::STACKTRACE_COLLAPSED) do |i|
        { "filename" => "app/f#{i}.rb", "function" => "call", "lineno" => i }
      end
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, stacktrace: { "frames" => frames })

      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='frames-more']")).to be_nil
      expect(doc.css("[data-test='frame']").size).to eq(Monitoring::Constants::STACKTRACE_COLLAPSED)
    end

    # CYRA-380 Scenario 1: nel dettaglio il chip «Utenti» mostrava sempre 0. Quando il contesto utente
    # non è mai arrivato, mostra «non tracciato» come link alla guida, non uno zero fuorviante.
    it "chip Utenti: «non tracciato» + link alla guida quando il dato non è mai arrivato (CYRA-380)" do
      sign_in(owner)
      group = create(:error_group, project:, users_count: 0)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)

      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='error-users']").text).to include(I18n.t("member.monitoring.users_untracked"))
      expect(doc.at_css("[data-test='error-users-untracked']")["href"]).to eq(member_guides_errors_path)
    end

    # CYRA-380 Scenario 2: dopo aver seguito la guida, il chip torna a mostrare il numero di persone.
    it "chip Utenti: il numero reale quando il contesto è tracciato (CYRA-380)" do
      sign_in(owner)
      group = create(:error_group, project:, users_count: 7)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)

      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='error-users']").text).to include("7")
      expect(doc.at_css("[data-test='error-users']").text).not_to include(I18n.t("member.monitoring.users_untracked"))
      expect(doc.at_css("[data-test='error-users-untracked']")).to be_nil
    end

    it "distingue il contatore aggregato («Eventi ricevuti») dalle occorrenze conservate quando i numeri divergono (CYRA-378)" do
      sign_in(owner)
      # events_count è cumulativo (2202); solo 2 occorrenze sopravvivono alla potatura per retention.
      group = create(:error_group, project:, title: "RuntimeError: boom", events_count: 2202)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)
      create(:error_event, group:, project:, occurred_at: 2.minutes.ago)

      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      # chip di testa: contatore aggregato con etichetta esplicita "Events received"
      events_chip = doc.at_css("[data-test='error-events']")
      expect(events_chip.text).to include("events received")
      expect(events_chip.text).to include("2,202")
      # blocco occorrenze: numero effettivo conservato con etichetta DISTINTA ("retained", non "total")
      expect(response.body).to include("2 retained")
      expect(response.body).not_to include("2 total ·")
    end

    it "spiega per quanti giorni le occorrenze vengono conservate, accanto al blocco occorrenze (CYRA-378)" do
      sign_in(owner)
      group = create(:error_group, project:, events_count: 2202)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)

      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      help = doc.at_css("[data-test='help-occurrences']")
      expect(help).to be_present
      days = Errors::Retention.for(project)
      expect(help.text).to include(days.to_s)
    end

    it "mantiene le stesse etichette anche quando i due numeri coincidono (CYRA-378)" do
      sign_in(owner)
      group = create(:error_group, project:, events_count: 2)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)
      create(:error_event, group:, project:, occurred_at: 2.minutes.ago)

      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='error-events']").text).to include(I18n.t("member.monitoring.label_events").downcase)
      expect(response.body).to include(I18n.t("member.monitoring.occurrences_count", count: 2, shown: 2))
      expect(doc.at_css("[data-test='help-occurrences']")).to be_present
    end

    it "gruppo di un altro progetto non visibile → 404 (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      foreign = create(:error_group, project: create(:project, organization: org))
      get member_monitoring_error_group_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "mostra params della richiesta (request.data + query_string) e dettagli ambiente (server/runtime/sdk/transaction)" do
      sign_in(owner)
      group = create(:error_group, project:, title: "RuntimeError: boom")
      create(:error_event, group:, project:, occurred_at: 1.minute.ago,
             server_name: "web-1", runtime: "ruby 4.0.5",
             payload: {
               "event_id" => "deadbeef", "level" => "error",
               "transaction" => "OrdersController#create",
               "sdk" => { "name" => "closeyourit-ruby", "version" => "0.4.0" },
               "request" => {
                 "method" => "POST", "url" => "https://app.test/orders",
                 "data" => { "name" => "Anna", "password" => "[FILTERED]" },
                 "query_string" => "page=2"
               }
             })
      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="error-params"')
      # CYRA-379: il valore oscurato (password) è mostrato con la dicitura leggibile, non con "[FILTERED]".
      expect(response.body).to include("Anna").and include("page=2")
      expect(response.body).to include(I18n.t("member.monitoring.value_scrubbed"))
      expect(response.body).not_to include("[FILTERED]")
      expect(response.body).to include('data-test="error-environment"')
      expect(response.body).to include("web-1").and include("ruby 4.0.5")
      expect(response.body).to include("closeyourit-ruby 0.4.0")
      expect(response.body).to include("OrdersController#create")
    end

    # CYRA-379: su alcuni progetti lo scrubber dell'SDK oscura filename/culprit/dettagli occorrenza,
    # e la pagina mostrava "[FILTERED]" senza spiegazione → errore illeggibile e apparente guasto.
    context "valori oscurati dalle regole di riservatezza (CYRA-379)" do
      it "Scenario 1+2: dicitura leggibile al posto della sigla, con link alla configurazione" do
        sign_in(owner)
        group = create(:error_group, project:,
                       culprit: "[FILTERED] in ActiveJob::Core::ClassMethods#deserialize")
        create(:error_event, group:, project:, occurred_at: 1.minute.ago,
               server_name: "[FILTERED]", runtime: "[FILTERED]",
               payload: {
                 "event_id" => "deadbeef", "level" => "error",
                 "sdk" => { "name" => "[FILTERED]", "version" => "1.0" }
               },
               stacktrace: { "frames" => [
                 { "filename" => "[FILTERED]", "function" => "deserialize", "in_app" => true }
               ] })
        get member_monitoring_error_group_path(group)

        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        # nessuna sigla tecnica visibile, ma la dicitura comprensibile sì
        expect(response.body).not_to include("[FILTERED]")
        expect(response.body).to include(I18n.t("member.monitoring.value_scrubbed"))
        # il metodo leggibile del culprit sopravvive accanto al token oscurato
        expect(response.body).to include("ActiveJob::Core::ClassMethods#deserialize")
        # collegamento alla configurazione (guida errori) accanto ai valori nascosti
        link = doc.at_css("[data-test='scrubbed-hint-link']")
        expect(link).to be_present
        expect(link["href"]).to eq(member_guides_errors_path)
      end

      it "oscura anche i valori annidati nei parametri e avvisa nella sezione request" do
        sign_in(owner)
        group = create(:error_group, project:, culprit: "App::Widget#render")
        create(:error_event, group:, project:, occurred_at: 1.minute.ago,
               payload: {
                 "event_id" => "deadbeef", "level" => "error",
                 "request" => {
                   "method" => "POST", "url" => "https://app.test/x",
                   "headers" => { "Authorization" => "[FILTERED]", "Accept" => "json" },
                   "data" => { "user" => { "password" => "[FILTERED]" }, "name" => "Anna" }
                 }
               })
        get member_monitoring_error_group_path(group)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("[FILTERED]") # nemmeno annidato nel JSON dei params
        expect(response.body).to include("Anna")
        expect(response.body).to include(I18n.t("member.monitoring.value_scrubbed"))
        # avviso + link presenti nella sezione request (header/params oscurati)
        expect(Nokogiri::HTML(response.body).at_css("[data-test='scrubbed-hint-link']")).to be_present
      end

      it "Scenario 3: un filename reale resta leggibile e senza avviso di oscuramento" do
        sign_in(owner)
        group = create(:error_group, project:, culprit: "App::Widget#render")
        create(:error_event, group:, project:, occurred_at: 1.minute.ago,
               stacktrace: { "frames" => [
                 { "filename" => "/app/app/views/events/show.html.erb", "function" => "call", "in_app" => true }
               ] })
        get member_monitoring_error_group_path(group)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("/app/app/views/events/show.html.erb")
        expect(response.body).not_to include('data-test="scrubbed-hint"')
        expect(response.body).not_to include(I18n.t("member.monitoring.value_scrubbed"))
      end
    end

    it "niente pannello params/ambiente quando i dati mancano" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)
      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-test="error-params"')
      expect(response.body).not_to include('data-test="error-environment"')
    end

    it "mostra il breakdown per OS e versione app quando gli eventi portano il device context" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago,
             os_name: "Android", os_version: "14", app_version: "1.2.0+45")
      create(:error_event, group:, project:, occurred_at: 2.minutes.ago,
             os_name: "Android", os_version: "14", app_version: "1.2.0+45")
      create(:error_event, group:, project:, occurred_at: 3.minutes.ago,
             os_name: "iOS", os_version: "17.4", app_version: "1.1.9+40")
      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="error-device-breakdown"')
      expect(response.body).to include("Android 14").and include("iOS 17.4")
      expect(response.body).to include("1.2.0+45").and include("1.1.9+40")
    end

    it "niente breakdown per gli eventi server-side (senza device context)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)
      get member_monitoring_error_group_path(group)

      expect(response.body).not_to include('data-test="error-device-breakdown"')
    end

    it "range valido nel param + filtri evento environment/release/level (rami then dei filtri)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago,
             environment: "production", release: "v1", level: :error)
      create(:error_event, group:, project:, occurred_at: 2.minutes.ago,
             environment: "staging", release: "v2", level: :warning)
      get member_monitoring_error_group_path(group),
          params: { range: "7d", environment: [ "production" ], release: [ "v1" ], level: [ "error" ] }
      expect(response).to have_http_status(:ok)
    end

    it "limita le occorrenze a una pagina (#{Monitoring::Constants::OCCURRENCES_PER_PAGE}) e pagina le restanti" do
      sign_in(owner)
      group = create(:error_group, project:)
      per = Monitoring::Constants::OCCURRENCES_PER_PAGE
      (per + 2).times { |i| create(:error_event, group:, project:, occurred_at: (i + 1).minutes.ago) }

      # CYRA-400: la pagina ne contiene 15, ma se ne mostrano 5 finché non si chiede di vederle tutte
      get member_monitoring_error_group_path(group)
      expect(response.body.scan('data-test="occurrence-row"').size)
        .to eq(Monitoring::Constants::OCCURRENCES_COLLAPSED)
      expect(response.body).to include('data-test="pagination-next"')

      get member_monitoring_error_group_path(group, occurrences: "all")
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(per)

      get member_monitoring_error_group_path(group, page: 2)
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(2)
    end

    it "il pager delle occorrenze preserva i filtri attivi (environment)" do
      sign_in(owner)
      group = create(:error_group, project:)
      per = Monitoring::Constants::OCCURRENCES_PER_PAGE
      (per + 2).times { |i| create(:error_event, group:, project:, environment: "production", occurred_at: (i + 1).minutes.ago) }
      create(:error_event, group:, project:, environment: "staging", occurred_at: 1.second.ago)

      get member_monitoring_error_group_path(group, environment: [ "production" ], page: 2)
      # pagina 2 del solo filtro production: le 2 occorrenze production restanti, nessuna staging
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(2)
    end

    # CYRA-46: drill-down dall'istogramma. Cliccare una barra apre la show con from/to del blocco →
    # le occorrenze sono filtrate a quella finestra temporale (correla lo spike alla release/deploy).
    it "drill-down: from/to filtrano le occorrenze alla finestra del blocco e mostrano il chip di reset" do
      sign_in(owner)
      group = create(:error_group, project:)
      spike = create(:error_event, group:, project:, occurred_at: 3.days.ago)
      3.times { create(:error_event, group:, project:, occurred_at: 1.minute.ago) }

      get member_monitoring_error_group_path(group, from: (3.days.ago - 1.hour).iso8601, to: (3.days.ago + 1.hour).iso8601)

      expect(response).to have_http_status(:ok)
      # solo lo spike di 3 giorni fa dentro la finestra, non le 3 occorrenze di oggi (event_id = colonna riga)
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(1)
      expect(response.body).to include(spike.event_id.truncate(12))
      expect(response.body).to include('data-test="bucket-filter"')
    end

    it "drill-down componibile coi filtri: bucket + environment restringono insieme" do
      sign_in(owner)
      group = create(:error_group, project:)
      target = create(:error_event, group:, project:, occurred_at: 3.days.ago, environment: "production")
      create(:error_event, group:, project:, occurred_at: 3.days.ago, environment: "staging")   # stesso blocco, altro env
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, environment: "production") # stesso env, altro blocco

      get member_monitoring_error_group_path(group,
                                             from: (3.days.ago - 1.hour).iso8601, to: (3.days.ago + 1.hour).iso8601,
                                             environment: [ "production" ])

      # il blocco esclude la production di oggi, environment esclude la staging del blocco → resta solo il target
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(1)
      expect(response.body).to include(target.event_id.truncate(12))
    end

    it "from/to malformati o incoerenti (to ≤ from) → ignorati, tutte le occorrenze, nessun chip" do
      sign_in(owner)
      group = create(:error_group, project:)
      2.times { create(:error_event, group:, project:, occurred_at: 1.minute.ago) }

      get member_monitoring_error_group_path(group, from: "not-a-date", to: "also-bad")

      expect(response).to have_http_status(:ok)
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(2)
      expect(response.body).not_to include('data-test="bucket-filter"')
    end

    it "l'istogramma espone barre cliccabili con from/to per il drill-down" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)

      get member_monitoring_error_group_path(group)

      expect(response.body).to include('data-test="bucket-link"')
      expect(response.body).to match(/<a href="[^"]*from=[^"]*"[^>]*data-test="bucket-link"/)
    end

    it "mantiene conteggio e occorrenze coerenti quando il tempo avanza tra rendering e click" do
      sign_in(owner)
      group = create(:error_group, project:)
      now = Time.zone.parse("2026-07-12 20:53:32.900000")
      bucket_to = now - 10.hours

      travel_to(now, with_usec: true)
      create(:error_event, group:, project:, occurred_at: bucket_to - 0.1.seconds)
      get member_monitoring_error_group_path(group, range: "24h")

      href = Nokogiri::HTML(response.body).at_css("a[data-test='bucket-link']")["href"]
      expect(href).to include("chart_at=")

      create(:error_event, group:, project:, occurred_at: bucket_to + 1.second)
      travel_to(now + 3.seconds, with_usec: true)
      get href

      doc = Nokogiri::HTML(response.body)
      active = doc.at_css("a[data-test='bucket-link'].ring-2")
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(1)
      expect(active["data-value"]).to eq(I18n.t("member.monitoring.tooltip_count", count: 1))
      expect(doc.at_css("input[name='chart_at']")["value"]).to eq(now.iso8601(6))
    end

    it "applica la finestra half-open con precisione al microsecondo" do
      sign_in(owner)
      group = create(:error_group, project:)
      from = Time.zone.parse("2026-07-12 10:23:32.123456")
      to = from + 30.minutes
      outside_before = create(:error_event, group:, project:, event_id: "outside-before", occurred_at: from - 0.000001.seconds)
      at_from = create(:error_event, group:, project:, event_id: "inside-at-from", occurred_at: from)
      before_to = create(:error_event, group:, project:, event_id: "inside-before-to", occurred_at: to - 0.000001.seconds)
      at_to = create(:error_event, group:, project:, event_id: "outside-at-to", occurred_at: to)

      get member_monitoring_error_group_path(group, from: from.iso8601(6), to: to.iso8601(6))

      expect(response.body.scan('data-test="occurrence-row"').size).to eq(2)
      expect(response.body).to include(at_from.event_id.truncate(12), before_to.event_id.truncate(12))
      expect(response.body).not_to include(outside_before.event_id.truncate(12), at_to.event_id.truncate(12))
    end

    it "ignora un anchor temporale malformato" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago)

      get member_monitoring_error_group_path(group, chart_at: "non-una-data")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="bucket-link"')
    end

    # CYRA-51: 'Logs of this request' segue l'occorrenza selezionata, non resta ancorato alla più
    # recente. I pannelli dei log sono resi server-side per OGNI occorrenza (toggle client-side via
    # Stimulus), ciascuno coi log del PROPRIO trace_id → nel body compaiono i log di tutte le occorrenze.
    it "rende i log correlati per ogni occorrenza (trace_id distinti), non solo la più recente" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "trace-recent")
      create(:error_event, group:, project:, occurred_at: 9.minutes.ago, trace_id: "trace-older")
      create(:log_entry, project:, trace_id: "trace-recent", message: "log della richiesta recente")
      create(:log_entry, project:, trace_id: "trace-older", message: "log della richiesta vecchia")

      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      # entrambi i set di log sono nel DOM (il vecchio in un pannello hidden, togglato client-side)
      expect(response.body).to include("log della richiesta recente")
      expect(response.body).to include("log della richiesta vecchia")
      # un pannello di log per occorrenza
      expect(response.body.scan('data-test="error-related-logs"').size).to eq(2)
    end

    it "mostra il trace_id di ogni occorrenza nel pannello dei log correlati (DoD)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "trace-aaa")
      create(:error_event, group:, project:, occurred_at: 9.minutes.ago, trace_id: "trace-bbb")

      get member_monitoring_error_group_path(group)

      expect(response.body).to include("trace-aaa").and include("trace-bbb")
    end

    it "occorrenza senza trace_id → pannello con empty state, nessun log correlato, nessun crash" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: nil)
      create(:log_entry, project:, trace_id: nil, message: "log senza trace")

      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      # CYRA-391 — una frase SOLA, e dice il motivo vero: manca il codice della richiesta.
      expect(Nokogiri::HTML(response.body).text).to include(I18n.t("member.monitoring.logs.in_error_no_trace"))
      expect(response.body).not_to include(I18n.t("member.monitoring.logs.in_error_none"))
      # trace_id nil non identifica una richiesta → nessuna correlazione
      expect(response.body).not_to include("log senza trace")
    end

    it "i log con lo stesso trace_id ma di un altro progetto non compaiono (scoping)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "shared-trace")
      create(:log_entry, project:, trace_id: "shared-trace", message: "log del progetto giusto")
      other_project = create(:project, organization: org)
      create(:log_entry, project: other_project, trace_id: "shared-trace", message: "log di un altro progetto")

      get member_monitoring_error_group_path(group)

      expect(response.body).to include("log del progetto giusto")
      expect(response.body).not_to include("log di un altro progetto")
    end

    it "limita a 20 i log correlati per occorrenza (cap per-trace a livello DB, non caricando tutto)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "busy-trace")
      25.times { |i| create(:log_entry, project:, trace_id: "busy-trace", message: "busy log #{i}", occurred_at: i.seconds.ago) }

      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      # un solo pannello (una occorrenza) con al massimo 20 righe di log
      expect(response.body.scan('data-test="error-related-log"').size).to eq(20)
    end

    # CYRA-60: dalla show errore si deve poter pivotare allo stream log COMPLETO del trace_id (info/debug
    # inclusi) e avere un segnale del volume. Il pannello mostra un badge "N log correlati" col totale
    # REALE (non il numero cappato mostrato) + un link allo stream log pre-filtrato per quel trace_id
    # (search per trace_id esatta, indice [project_id, trace_id]).
    it "mostra il badge 'N log correlati' col totale reale della richiesta (CYRA-60)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "trace-x")
      3.times { |i| create(:log_entry, project:, trace_id: "trace-x", message: "log #{i}") }

      get member_monitoring_error_group_path(group)

      expect(response.body).to include('data-test="error-related-logs-count"')
      expect(response.body).to include(I18n.t("member.monitoring.logs.in_error_count", count: 3))
    end

    it "il badge conta il totale reale anche oltre il cap di 20 mostrati (CYRA-60)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "busy-trace")
      25.times { |i| create(:log_entry, project:, trace_id: "busy-trace", message: "busy #{i}", occurred_at: i.seconds.ago) }

      get member_monitoring_error_group_path(group)

      # 20 righe mostrate, ma il badge dichiara il totale onesto (25)
      expect(response.body.scan('data-test="error-related-log"').size).to eq(20)
      expect(response.body).to include(I18n.t("member.monitoring.logs.in_error_count", count: 25))
    end

    it "il badge conta solo i log del progetto del gruppo, non un altro con lo stesso trace (BOLA, CYRA-60)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "shared-trace")
      create(:log_entry, project:, trace_id: "shared-trace", message: "log del progetto giusto")
      other_project = create(:project, organization: org)
      create(:log_entry, project: other_project, trace_id: "shared-trace", message: "log di un altro progetto")

      get member_monitoring_error_group_path(group)

      # il badge dichiara 1 (solo il log del progetto del gruppo), non 2
      expect(response.body).to include(I18n.t("member.monitoring.logs.in_error_count", count: 1))
      expect(response.body).not_to include(I18n.t("member.monitoring.logs.in_error_count", count: 2))
    end

    it "offre un link allo stream log pre-filtrato per trace_id esatto + progetto del gruppo (CYRA-60)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "trace-pivot")
      create(:log_entry, project:, trace_id: "trace-pivot", message: "log pivotabile")

      get member_monitoring_error_group_path(group)

      expect(response.body).to include('data-test="error-related-logs-all"')
      # trace_id ESATTO (non q=, che farebbe anche message ILIKE) + project_id del gruppo → scoping
      # identico al badge, niente log estranei/cross-progetto.
      expect(response.body).to include("trace_id=trace-pivot")
      expect(response.body).to include("project_id=#{project.id}")
    end

    it "trace_id presente ma nessun log → nessun badge né link 'vedi tutti' (CYRA-60)" do
      sign_in(owner)
      group = create(:error_group, project:)
      create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "lonely-trace")

      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.monitoring.logs.in_error_none"))
      expect(response.body).not_to include('data-test="error-related-logs-count"')
      expect(response.body).not_to include('data-test="error-related-logs-all"')
    end

    it "gruppo senza occorrenze → pannello log correlati vuoto, nessun crash" do
      sign_in(owner)
      group = create(:error_group, project:)

      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="error-related-logs"')
      expect(response.body).to include(I18n.t("member.monitoring.logs.in_error_none"))
    end
  end

  describe "similar (cluster AI, asincrono)" do
    it "l'errore del gateway arriva via job: la richiesta finisce failed col codice AI" do
      sign_in(owner)
      create(:integration_credential, organization: org) # CYRA-548
      group = create(:error_group, project:)
      allow(Errors::FindSimilarGroups).to receive(:call).and_return(
        Result.err(AppError.new("AI giù", code: "R502-AI-001", status: :bad_gateway))
      )

      perform_enqueued_jobs do
        post similar_member_monitoring_error_group_path(group)
      end

      expect(response).to have_http_status(:accepted)
      request_record = Ai::Request.find(response.parsed_body.dig("data", "request_id"))
      expect(request_record.reload).to be_status_failed
      expect(request_record.error_code).to eq("R502-AI-001")
    end
  end

  describe "triage" do
    let(:group) { create(:error_group, project:, status: :unresolved) }

    it "admin PATCH resolve → resolved" do
      sign_in(owner)
      patch resolve_member_monitoring_error_group_path(group)
      expect(group.reload).to be_status_resolved
      expect(response).to redirect_to(member_monitoring_error_group_path(group))
    end

    it "admin PATCH ignore → ignored" do
      sign_in(owner)
      patch ignore_member_monitoring_error_group_path(group)
      expect(group.reload).to be_status_ignored
    end

    it "admin PATCH reopen → unresolved" do
      sign_in(owner)
      group.status_resolved!
      patch reopen_member_monitoring_error_group_path(group)
      expect(group.reload).to be_status_unresolved
    end

    it "member semplice → forbidden (redirect), stato invariato" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      patch resolve_member_monitoring_error_group_path(group)
      expect(group.reload).to be_status_unresolved
      expect(response).to redirect_to(root_path)
    end
  end

  describe "promote" do
    let(:group) { create(:error_group, project:, title: "RuntimeError: boom", culprit: "App::X#y") }

    it "admin → crea ticket e collega il gruppo" do
      sign_in(owner)
      expect { post promote_member_monitoring_error_group_path(group) }.to change(Ticketing::Ticket, :count).by(1)
      expect(group.reload).to be_promoted
      expect(response).to redirect_to(member_monitoring_error_group_path(group))
    end

    it "gruppo già promosso → alert, nessun secondo ticket" do
      sign_in(owner)
      post promote_member_monitoring_error_group_path(group)
      expect { post promote_member_monitoring_error_group_path(group) }.not_to change(Ticketing::Ticket, :count)
      expect(flash[:alert]).to be_present
    end

    it "member semplice → forbidden" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      expect { post promote_member_monitoring_error_group_path(group) }.not_to change(Ticketing::Ticket, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  # CYRA-153: assegnazione dell'errore a una persona (asimmetria coi ticket colmata).
  describe "PATCH assign" do
    it "owner assegna un membro dell'org e torna alla show" do
      sign_in(owner)
      group = create(:error_group, project:)

      patch assign_member_monitoring_error_group_path(group), params: { assignee_id: admin.id }

      expect(response).to redirect_to(member_monitoring_error_group_path(group))
      expect(group.reload.assignee_id).to eq(admin.id)
    end

    it "owner disassegna con assignee_id vuoto" do
      sign_in(owner)
      group = create(:error_group, project:, assignee: admin)

      patch assign_member_monitoring_error_group_path(group), params: { assignee_id: "" }

      expect(group.reload.assignee_id).to be_nil
    end

    # L'assegnatario si mostra nella show, non nella riga index: il realtime è un refresh del gruppo,
    # così le show aperte dagli altri non restano obsolete.
    it "aggiorna la show in tempo reale con un refresh del gruppo" do
      sign_in(owner)
      group = create(:error_group, project:)

      expect(Errors::Broadcast).to receive(:refresh_group).with(group)

      patch assign_member_monitoring_error_group_path(group), params: { assignee_id: admin.id }
    end

    # Chi vede il progetto ma non ha errors.assign non deve poter cambiare l'assegnatario.
    it "member senza errors.assign → redirect e nessun cambiamento" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      group = create(:error_group, project:)

      patch assign_member_monitoring_error_group_path(group), params: { assignee_id: admin.id }

      expect(response).to redirect_to(root_path)
      expect(group.reload.assignee_id).to be_nil
    end
  end
  # CYRA-383 — tre contatori con lo stesso aspetto che parlavano di insiemi diversi: uno seguiva i
  # filtri, gli altri restavano globali, e i loro numeri non sommavano al totale.
  describe "i contatori in cima all'elenco" do
    before do
      allow_n_plus_one do
        create(:error_group, project:, status: :unresolved, title: "A")
        create(:error_group, project:, status: :unresolved, title: "B")
        create(:error_group, project:, status: :resolved, title: "C")
        create(:error_group, project:, status: :ignored, title: "D")
      end
      sign_in(owner)
    end

    def chip(body, test_id)
      node = Nokogiri::HTML(body).at_css(%([data-test="#{test_id}"]))
      { text: node.text, href: node["href"], active: node["aria-current"] }
    end

    it "conta tutti gli stati, e la somma è il totale dichiarato" do
      get member_monitoring_error_groups_path

      body = response.body
      expect(chip(body, "stat-unresolved")[:text]).to include("2")
      expect(chip(body, "stat-resolved")[:text]).to include("1")
      expect(chip(body, "stat-ignored")[:text]).to include("1")
      expect(chip(body, "stat-issues")[:text]).to include("4")
    end

    it "ogni contatore è un filtro, e quello acceso si riconosce" do
      get member_monitoring_error_groups_path(status: "resolved")

      body = response.body
      expect(chip(body, "stat-resolved")[:href]).to include("status=resolved")
      expect(chip(body, "stat-resolved")[:active]).to eq("true")
      expect(chip(body, "stat-unresolved")[:active]).to be_nil
    end

    it "i numeri non cambiano al cambiare del filtro di stato: descrivono lo stesso insieme" do
      get member_monitoring_error_groups_path(status: "resolved")

      body = response.body
      expect(chip(body, "stat-unresolved")[:text]).to include("2")
      expect(chip(body, "stat-issues")[:text]).to include("4")
    end

    it "gli altri filtri invece li seguono" do
      altro = create(:project, organization: org)
      create(:error_group, project: altro, status: :unresolved, title: "E")

      get member_monitoring_error_groups_path(project_id: [ altro.id ])

      body = response.body
      expect(chip(body, "stat-unresolved")[:text]).to include("1")
      expect(chip(body, "stat-issues")[:text]).to include("1")
    end
  end
  # CYRA-388 — il livello si legge in italiano accanto a stati italiani, ma il VALORE che viaggia
  # nei filtri e che mandano gli SDK non cambia.
  describe "i livelli di gravità" do
    it "si leggono in italiano nell'elenco" do
      # La pagina si rende nella lingua di chi guarda: senza dichiararla, l'account ricade sul
      # default (inglese) e la prova passava solo per l'ordine in cui girava.
      owner.update!(locale: "it")
      create(:error_group, project:, level: "error", title: "Boom")
      sign_in(owner)

      get member_monitoring_error_groups_path

      I18n.with_locale(:it) do
        expect(Nokogiri::HTML(response.body).text).to include(I18n.t("member.monitoring.levels.error"))
      end
    end

    it "il filtro continua a viaggiare col valore dell'SDK" do
      grave = create(:error_group, project:, level: "fatal", title: "Fatale")
      create(:error_group, project:, level: "info", title: "Informativo")
      sign_in(owner)

      get member_monitoring_error_groups_path(level: [ "fatal" ])

      expect(response.body).to include(grave.title)
      expect(response.body).not_to include("Informativo")
    end

    it "un livello fuori vocabolario si mostra com'è arrivato" do
      expect(helper_level_label("qualcosa_di_nuovo")).to eq("qualcosa_di_nuovo")
    end

    def helper_level_label(level)
      ActionController::Base.helpers.extend(MonitoringHelper)
      ActionController::Base.helpers.error_level_label(level)
    end
  end
  # CYRA-391 — il codice della richiesta era scritto a schermo ma non cliccabile, e in coda
  # comparivano due frasi negative di fila.
  describe "il pannello dei registri correlati" do
    let(:group) { create(:error_group, project:, title: "Boom") }

    it "il codice della richiesta apre i registri di quella richiesta" do
      create(:error_event, group:, project:, trace_id: "abc123")
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      link = Nokogiri::HTML(response.body).at_css('[data-test="error-related-logs-trace-link"]')
      expect(link).to be_present
      expect(link.text).to eq("abc123")
      expect(link["href"]).to include("trace_id=abc123")
    end

    it "senza codice della richiesta non stampa due negazioni di fila" do
      create(:error_event, group:, project:, trace_id: nil)
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="error-related-logs-trace"]')).to be_nil
      expect(html.at_css('[data-test="error-related-logs-none"]').text).to include(
        I18n.t("member.monitoring.logs.in_error_no_trace")
      )
    end
  end

  describe "i registri filtrati per richiesta" do
    it "senza risultati spiegano perché, invece di dire «nessun filtro corrisponde»" do
      sign_in(owner)

      get member_monitoring_log_entries_path(trace_id: "mai-visto")

      expect(response.body).to include('data-test="logs-no-match-trace"')
      expect(Nokogiri::HTML(response.body).text).to include(I18n.t("member.monitoring.logs.no_match_trace"))
    end
  end
  # CYRA-394 — due SHA da quaranta caratteri affiancati in una colonna stretta si accavallavano fino
  # a non leggersi, ed è il dato che chiude un'indagine in trenta secondi.
  describe "i rilasci nel dettaglio" do
    it "lo SHA si legge a sette caratteri e si copia per intero" do
      sha = "c543d36352fd310ea6bf06bd3558e0ba83a5ac74"
      group = create(:error_group, project:, release: sha, first_seen_release: "v0.1.0")
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="group-last-release"]').text.strip).to eq("c543d36")
      expect(response.body).to include(sha) # il valore intero resta, per la copia
      expect(html.at_css('[data-test="group-last-release-copy"]')).to be_present
    end

    it "una versione leggibile resta com'è" do
      group = create(:error_group, project:, release: "v0.77.4", first_seen_release: "v0.63.0")
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="group-last-release"]').text.strip).to eq("v0.77.4")
      expect(html.at_css('[data-test="group-first-release"]').text.strip).to eq("v0.63.0")
    end

    it "quando i due rilasci coincidono lo dice in una riga sola" do
      group = create(:error_group, project:, release: "v0.77.4", first_seen_release: "v0.77.4")
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      expect(response.body).to include('data-test="group-release-same"')
      expect(Nokogiri::HTML(response.body).text).to include(I18n.t("member.monitoring.detail_release_same"))
      expect(response.body).not_to include('data-test="group-first-release"')
    end

    it "col repository agganciato lo SHA porta alla modifica" do
      sha = "c543d36352fd310ea6bf06bd3558e0ba83a5ac74"
      create(:github_repository, project:, full_name: "bussolabs/demo")
      group = create(:error_group, project:, release: sha, first_seen_release: sha)
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      link = Nokogiri::HTML(response.body).at_css('[data-test="group-last-release"]')
      expect(link["href"]).to eq("https://github.com/bussolabs/demo/commit/#{sha}")
    end

    it "senza rilascio resta un trattino, senza gesti che non fanno niente" do
      group = create(:error_group, project:, release: nil, first_seen_release: nil)
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="group-last-release"]').text.strip).to eq("—")
      expect(html.at_css('[data-test="group-last-release-copy"]')).to be_nil
    end
  end
end
