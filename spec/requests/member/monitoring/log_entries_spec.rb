# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::LogEntries", type: :request do
  let(:org) { create(:organization) }
  # Gli attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune li faceva pagare tutti a tutti.
  let(:owner) { account_with_membership(:owner) }
  let(:member) { account_with_membership(:member) }
  let(:project) { create(:project, organization: org) }

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
      get member_monitoring_log_entries_path
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200 e vede i log dell'org" do
      sign_in(owner)
      create(:log_entry, project:, message: "disk almost full")
      get member_monitoring_log_entries_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("disk almost full")
    end

    # Il livello si legge nella lingua della pagina, come nei filtri e negli errori («errore», non «error»).
    it "il livello della riga è tradotto" do
      owner.update!(locale: "it")
      sign_in(owner)
      create(:log_entry, project:, message: "disk almost full", level: :warning)
      get member_monitoring_log_entries_path
      row = Nokogiri::HTML(response.body).at_css('[data-test="log-entry-row"]')
      expect(row.text).to include("avviso")
      expect(row.text).not_to include("warning")
    end

    it "la project key non è indigo (non è un link, One-Voice)" do
      sign_in(owner)
      create(:log_entry, project:, message: "disk almost full")
      get member_monitoring_log_entries_path
      row = Nokogiri::HTML(response.body).at_css('[data-test="log-entry-row"]')
      key_span = row.css("span").find { |span| span.text.strip == project.key }
      expect(key_span["class"]).to include("text-gray-500")
      expect(key_span["class"]).not_to include("text-indigo-600")
    end

    it "member senza assegnazioni → nessun log (strict)" do
      sign_in(member)
      create(:log_entry, project:, message: "SecretLog")
      get member_monitoring_log_entries_path
      expect(response.body).not_to include("SecretLog")
    end

    it "member assegnato vede il progetto, non altri (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      create(:log_entry, project:, message: "VisibleLog")
      create(:log_entry, project: create(:project, organization: org), message: "HiddenLog")
      get member_monitoring_log_entries_path
      expect(response.body).to include("VisibleLog")
      expect(response.body).not_to include("HiddenLog")
    end

    it "filtra per level" do
      sign_in(owner)
      create(:log_entry, project:, level: :error, message: "ErrLog")
      create(:log_entry, project:, level: :info, message: "InfoLog")
      get member_monitoring_log_entries_path, params: { level: [ "error" ] }
      expect(response.body).to include("ErrLog")
      expect(response.body).not_to include("InfoLog")
    end

    it "filtra per environment" do
      sign_in(owner)
      create(:log_entry, project:, environment: "production", message: "ProdLog")
      create(:log_entry, project:, environment: "staging", message: "StagingLog")
      get member_monitoring_log_entries_path, params: { environment: [ "production" ] }
      expect(response.body).to include("ProdLog")
      expect(response.body).not_to include("StagingLog")
    end

    it "filtra per project" do
      sign_in(owner)
      other = create(:project, organization: org)
      create(:log_entry, project:, message: "MineLog")
      create(:log_entry, project: other, message: "OtherLog")
      get member_monitoring_log_entries_path, params: { project_id: [ project.id ] }
      expect(response.body).to include("MineLog")
      expect(response.body).not_to include("OtherLog")
    end

    it "cerca nel messaggio" do
      sign_in(owner)
      create(:log_entry, project:, message: "Searchable thing")
      create(:log_entry, project:, message: "Hidden item")
      get member_monitoring_log_entries_path, params: { q: "Searchable" }
      expect(response.body).to include("Searchable")
      expect(response.body).not_to include("Hidden item")
    end

    # CYRA-60: pivot dalla show errore ("Vedi tutti i log di questa richiesta"). Filtro trace_id ESATTO,
    # distinto da q= che fa anche message ILIKE: un log che MENZIONA il trace nel messaggio non entra.
    it "filtra per trace_id esatto, non per message-match (CYRA-60)" do
      sign_in(owner)
      create(:log_entry, project:, trace_id: "abc123", message: "log della richiesta")
      create(:log_entry, project:, trace_id: "other-trace", message: "menziona abc123 nel testo")
      create(:log_entry, project:, trace_id: nil, message: "estraneo")
      get member_monitoring_log_entries_path, params: { trace_id: "abc123" }
      expect(response.body).to include("log della richiesta")
      expect(response.body).not_to include("menziona abc123 nel testo")
      expect(response.body).not_to include("estraneo")
    end

    it "trace_id + project_id esclude un altro progetto visibile con lo stesso trace (BOLA, CYRA-60)" do
      sign_in(owner)
      other = create(:project, organization: org)
      create(:log_entry, project:, trace_id: "shared", message: "log del progetto giusto")
      create(:log_entry, project: other, trace_id: "shared", message: "log di un altro progetto")
      get member_monitoring_log_entries_path, params: { trace_id: "shared", project_id: [ project.id ] }
      expect(response.body).to include("log del progetto giusto")
      expect(response.body).not_to include("log di un altro progetto")
    end

    it "con since=today mostra solo i log di oggi (deep-link KPI 'log error/fatal oggi')" do
      sign_in(owner)
      create(:log_entry, project:, level: :error, message: "TodayGrave", occurred_at: Time.current)
      create(:log_entry, project:, level: :error, message: "OldGrave", occurred_at: 2.days.ago)
      get member_monitoring_log_entries_path, params: { level: [ "error" ], since: "today" }
      expect(response.body).to include("TodayGrave")
      expect(response.body).not_to include("OldGrave")
    end

    # CYRA-56: filtro range temporale (from/to) per scopare a una finestra d'incidente senza
    # paginare a ritroso. Istanti assoluti → deterministici (mai orologio reale).
    describe "filtro range temporale (from/to)" do
      before { sign_in(owner) }

      # Incidente del 2026-07-09 tra le 14:00 e le 14:10 (tz app Rome).
      let(:window_from) { "2026-07-09T14:00" }
      let(:window_to) { "2026-07-09T14:10" }

      it "restringe alla finestra [from, to], escludendo prima e dopo" do
        create(:log_entry, project:, message: "InWindow", occurred_at: Time.zone.local(2026, 7, 9, 14, 5))
        create(:log_entry, project:, message: "BeforeWindow", occurred_at: Time.zone.local(2026, 7, 9, 13, 55))
        create(:log_entry, project:, message: "AfterWindow", occurred_at: Time.zone.local(2026, 7, 9, 14, 20))
        get member_monitoring_log_entries_path, params: { from: window_from, to: window_to }
        expect(response.body).to include("InWindow")
        expect(response.body).not_to include("BeforeWindow")
        expect(response.body).not_to include("AfterWindow")
      end

      it "bounds the range by created_at too, allowing for clients whose clock runs ahead (CYRA-891)" do
        at = Time.zone.local(2026, 7, 9, 14, 5)
        create(:log_entry, project:, message: "FastClock", occurred_at: at, created_at: at - 50.minutes)
        sql = []
        callback = ->(*, payload) { sql << payload[:sql] if payload[:sql].include?("logs_entries") }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          get member_monitoring_log_entries_path, params: { from: window_from, to: window_to }
        end

        expect(response.body).to include("FastClock")
        expect(sql.grep(/"occurred_at" >=/)).to all(include('"created_at" >='))
      end

      it "i confini from e to sono inclusivi (±1s esclusi)" do
        create(:log_entry, project:, message: "AtFrom", occurred_at: Time.zone.local(2026, 7, 9, 14, 0, 0))
        create(:log_entry, project:, message: "AtTo", occurred_at: Time.zone.local(2026, 7, 9, 14, 10, 0))
        create(:log_entry, project:, message: "JustBefore", occurred_at: Time.zone.local(2026, 7, 9, 13, 59, 59))
        create(:log_entry, project:, message: "JustAfter", occurred_at: Time.zone.local(2026, 7, 9, 14, 10, 1))
        get member_monitoring_log_entries_path, params: { from: window_from, to: window_to }
        expect(response.body).to include("AtFrom")
        expect(response.body).to include("AtTo")
        expect(response.body).not_to include("JustBefore")
        expect(response.body).not_to include("JustAfter")
      end

      it "con solo from mostra i log da quell'istante in poi" do
        create(:log_entry, project:, message: "RecentLog", occurred_at: Time.zone.local(2026, 7, 9, 15, 0))
        create(:log_entry, project:, message: "AncientLog", occurred_at: Time.zone.local(2026, 7, 9, 10, 0))
        get member_monitoring_log_entries_path, params: { from: window_from }
        expect(response.body).to include("RecentLog")
        expect(response.body).not_to include("AncientLog")
      end

      it "con solo to mostra i log fino a quell'istante" do
        create(:log_entry, project:, message: "EarlyLog", occurred_at: Time.zone.local(2026, 7, 9, 12, 0))
        create(:log_entry, project:, message: "LateLog", occurred_at: Time.zone.local(2026, 7, 9, 16, 0))
        get member_monitoring_log_entries_path, params: { to: window_to }
        expect(response.body).to include("EarlyLog")
        expect(response.body).not_to include("LateLog")
      end

      it "normalizza from/to ISO8601 con offset al formato datetime-local (campo non vuoto, vincolo visibile)" do
        create(:log_entry, project:, message: "InWindow", occurred_at: Time.zone.local(2026, 7, 9, 14, 5))
        # Deep-link/drill-down istogramma: from/to arrivano in ISO8601 con offset, che l'input
        # datetime-local rifiuterebbe lasciando il campo vuoto (filtro attivo ma invisibile).
        get member_monitoring_log_entries_path,
            params: { from: "2026-07-09T14:00:00+02:00", to: "2026-07-09T14:10:00+02:00" }
        expect(response.body).to include("InWindow")
        html = Nokogiri::HTML(response.body)
        expect(html.at_css('[data-test="logs-range-from"]')["value"]).to eq("2026-07-09T14:00")
        expect(html.at_css('[data-test="logs-range-to"]')["value"]).to eq("2026-07-09T14:10")
      end

      # CYRA-340: due date illeggibili non sono un periodo, e la pagina ricade sulle ultime
      # ventiquattro ore — il predefinito dichiarato — invece di mostrare l'intero stream.
      it "lascia i campi vuoti quando il range è malformato (nessuna spazzatura nel value)" do
        get member_monitoring_log_entries_path, params: { range: "custom", from: "not-a-date", to: "garbage" }
        html = Nokogiri::HTML(response.body)
        expect(html.at_css('[data-test="logs-range-from"]')["value"]).to eq("")
        expect(html.at_css('[data-test="logs-range-to"]')["value"]).to eq("")
      end

      it "un range malformato non fa crashare la pagina (ricade sul periodo predefinito)" do
        create(:log_entry, project:, message: "AnyLog", occurred_at: 1.hour.ago)
        get member_monitoring_log_entries_path, params: { from: "not-a-date", to: "garbage" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("AnyLog")
        expect(Nokogiri::HTML(response.body).at_css('[data-test="filter-chip-range"]')["hidden"]).not_to be_nil
      end

      # CYRA-340: scritte al contrario, le due date restano la finestra che si voleva. Prima davano
      # una pagina vuota e muta, che è il modo peggiore di dire «hai invertito gli estremi».
      it "con from successivo a to rimette gli estremi in ordine invece di svuotare la pagina" do
        create(:log_entry, project:, message: "Whatever", occurred_at: Time.zone.local(2026, 7, 9, 14, 5))
        create(:log_entry, project:, message: "FuoriFinestra", occurred_at: Time.zone.local(2026, 7, 9, 18, 0))
        get member_monitoring_log_entries_path, params: { from: window_to, to: window_from }
        expect(response.body).to include("Whatever")
        expect(response.body).not_to include("FuoriFinestra")
      end

      it "compone il range coi filtri esistenti (level dentro la finestra)" do
        create(:log_entry, project:, level: :error, message: "ErrInWindow", occurred_at: Time.zone.local(2026, 7, 9, 14, 5))
        create(:log_entry, project:, level: :info, message: "InfoInWindow", occurred_at: Time.zone.local(2026, 7, 9, 14, 6))
        create(:log_entry, project:, level: :error, message: "ErrOutWindow", occurred_at: Time.zone.local(2026, 7, 9, 18, 0))
        get member_monitoring_log_entries_path, params: { from: window_from, to: window_to, level: [ "error" ] }
        expect(response.body).to include("ErrInWindow")
        expect(response.body).not_to include("InfoInWindow")
        expect(response.body).not_to include("ErrOutWindow")
      end
    end

    # CYRA-59: i facet dell'header (dropdown environment via DISTINCT, chip conteggi via GROUP BY level)
    # aggregano l'intero stream visibile — non i filtri di lista. Su decine di milioni di righe un
    # ricalcolo a ogni apertura/paginazione/filtro è un full-scan ripetuto. Sono cache-ati con TTL breve
    # keyed sui progetti visibili, così render ripetuti dello stesso scope non ri-scansionano il DB.
    describe "carico DB dei facet (dropdown environment + chip conteggi)" do
      let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

      # Conta le SQL di aggregato dei facet emesse dentro il blocco: il DISTINCT environment e il
      # GROUP BY level sono le due query costose che il ticket vuole cache-are.
      def facet_query_counts
        counts = { distinct_environment: 0, group_level: 0 }
        subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          sql = payload[:sql]
          counts[:distinct_environment] += 1 if sql.match?(/SELECT DISTINCT "logs_entries"\."environment"/i)
          counts[:group_level] += 1 if sql.match?(/GROUP BY "logs_entries"\."level"/i)
        end
        yield
        counts
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end

      before do
        sign_in(owner)
        allow(Rails).to receive(:cache).and_return(memory_cache)
        create(:log_entry, project:, environment: "production", level: :error, message: "ProdErr")
      end

      # CYRA-354 — i GROUP BY level sono ora DUE per pagina: quello dei facet (globale, cached) e
      # quello dei conteggi in cima, che seguono il filtro e per definizione non si possono
      # riusare fra filtri diversi. Su due render: 1 cached + 2 filtrati.
      it "calcola DISTINCT environment e i facet una sola volta su due render dello stesso scope" do
        counts = facet_query_counts do
          get member_monitoring_log_entries_path
          get member_monitoring_log_entries_path
        end
        expect(counts[:distinct_environment]).to eq(1)
        expect(counts[:group_level]).to eq(3)
      end

      it "non ricalcola i facet quando cambiano i filtri di lista (i facet sono globali sullo scope)" do
        counts = facet_query_counts do
          get member_monitoring_log_entries_path
          get member_monitoring_log_entries_path, params: { level: [ "error" ] }
          get member_monitoring_log_entries_path, params: { q: "Prod" }
        end
        expect(counts[:distinct_environment]).to eq(1)
        # 1 aggregazione dei facet (cached, invariata al cambio filtro) + 1 per render dei conteggi
        # filtrati, che dipendono dal filtro e quindi non sono riusabili.
        expect(counts[:group_level]).to eq(4)
      end

      it "resta corretto: il dropdown mostra gli environment distinti e i chip i conteggi giusti" do
        create(:log_entry, project:, environment: "staging", level: :warning, message: "StagWarn")
        get member_monitoring_log_entries_path
        html = Nokogiri::HTML(response.body)
        expect(html.at_css('[data-test="logs-stat-total"]').text).to include("2")
        expect(html.at_css('[data-test="logs-stat-errors"]').text).to include("1")
        expect(html.at_css('[data-test="logs-stat-warnings"]').text).to include("1")
        expect(response.body).to include("staging")
        expect(response.body).to include("production")
      end

      it "la cache è per-scope: un member con progetti diversi non eredita i facet altrui (BOLA)" do
        create(:project_membership, account: member, project: create(:project, organization: org))
        # Owner scalda la cache col suo scope (vede 'production').
        get member_monitoring_log_entries_path
        # Il member vede solo il proprio progetto (nessun log) → chiave cache diversa, zero conteggi.
        sign_in(member)
        get member_monitoring_log_entries_path
        html = Nokogiri::HTML(response.body)
        expect(html.at_css('[data-test="logs-stat-total"]').text).to include("0")
        expect(response.body).not_to include("ProdErr")
      end
    end

    # CYRA-61: la retention purga i log oltre la finestra, ma la pagina non lo diceva → uno stream vuoto
    # (o un log vecchio già eliminato) sembra un bug "i log non arrivano" e genera un ticket di supporto.
    # La nota comunica la finestra: nearest-wins per-progetto (progetto → org → god → default), min/max
    # sui progetti visibili (o sui soli filtrati), single se coincidono altrimenti range.
    describe "nota di retention (CYRA-61)" do
      def retention_note(body) = Nokogiri::HTML(body).at_css('[data-test="logs-retention-note"]')

      it "mostra la finestra di retention di default quando non ci sono override" do
        sign_in(owner)
        create(:log_entry, project:, message: "anything")
        get member_monitoring_log_entries_path
        note = retention_note(response.body)
        expect(note).to be_present
        expect(note.text).to include(Logs::Constants::RETENTION_DEFAULT_DAYS.to_s)
      end

      it "usa la retention del progetto quando c'è un override (nearest-wins)" do
        sign_in(owner)
        project.update!(logs_retention_days: 30)
        create(:log_entry, project:, message: "anything")
        get member_monitoring_log_entries_path
        expect(response.body).to include(I18n.t("member.monitoring.logs.retention_note.single", count: 30))
      end

      # Scenario del ticket: il progetto esiste ma lo stream è vuoto (log di 20 giorni fa purgato) →
      # l'empty-state deve spiegare la finestra, così l'utente non pensa a un bug di ingest.
      it "mostra la nota nell'empty-state quando non c'è alcun log" do
        sign_in(owner)
        project # progetto visibile senza log (già purgati / mai inviati)
        get member_monitoring_log_entries_path
        empty = Nokogiri::HTML(response.body).at_css('[data-test="logs-empty"]')
        expect(empty).to be_present
        expect(empty.text).to include(Logs::Constants::RETENTION_DEFAULT_DAYS.to_s)
      end

      # Cercare un log di 20 giorni fa spesso passa da un filtro (range/ricerca) che non matcha più nulla:
      # anche il no-match deve ricordare la finestra di retention.
      it "mostra la nota nel no-match quando i filtri non corrispondono a nulla" do
        sign_in(owner)
        create(:log_entry, project:, message: "present log")
        get member_monitoring_log_entries_path, params: { q: "zzz-non-esiste" }
        no_match = Nokogiri::HTML(response.body).at_css('[data-test="logs-no-match"]')
        expect(no_match).to be_present
        expect(no_match.text).to include(Logs::Constants::RETENTION_DEFAULT_DAYS.to_s)
      end

      it "mostra un range quando i progetti visibili hanno retention diverse" do
        sign_in(owner)
        project.update!(logs_retention_days: 7)
        create(:project, organization: org).update!(logs_retention_days: 30)
        create(:log_entry, project:, message: "anything")
        note = (get(member_monitoring_log_entries_path); retention_note(response.body))
        expect(note.text).to include("7").and include("30")
      end

      it "filtrando per un progetto comunica la retention di quel progetto, non il range" do
        sign_in(owner)
        project.update!(logs_retention_days: 7)
        create(:project, organization: org).update!(logs_retention_days: 30)
        create(:log_entry, project:, message: "anything")
        get member_monitoring_log_entries_path, params: { project_id: [ project.id ] }
        note = retention_note(response.body)
        expect(note.text).to include(I18n.t("member.monitoring.logs.retention_note.single", count: 7))
        expect(note.text).not_to include("30")
      end

      it "un member senza progetti visibili non vede la nota (niente da comunicare)" do
        sign_in(member)
        get member_monitoring_log_entries_path
        expect(retention_note(response.body)).to be_nil
      end

      # La nota compare esattamente una volta: nel corpo (empty-state/no-match) O nel footer, mai duplicata.
      def retention_notes_count(body) = Nokogiri::HTML(body).css('[data-test="logs-retention-note"]').size

      it "nell'empty-state mostra la nota una sola volta (non la duplica nel footer)" do
        sign_in(owner)
        project
        get member_monitoring_log_entries_path
        expect(retention_notes_count(response.body)).to eq(1)
      end

      it "con log a schermo mostra la nota una sola volta (solo footer)" do
        sign_in(owner)
        create(:log_entry, project:, message: "anything")
        get member_monitoring_log_entries_path
        expect(retention_notes_count(response.body)).to eq(1)
      end
    end
  end

  describe "GET show" do
    it "owner → 200 con messaggio e attributi" do
      sign_in(owner)
      entry = create(:log_entry, project:, message: "boom happened", data: { "user_id" => 9 })
      get member_monitoring_log_entry_path(entry)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("boom happened")
      expect(response.body).to include("user_id")
    end

    it "log di un progetto non visibile → 404 (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      foreign = create(:log_entry, project: create(:project, organization: org))
      get member_monitoring_log_entry_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "correla i log della stessa richiesta (trace_id)" do
      sign_in(owner)
      entry = create(:log_entry, project:, trace_id: "trace-1", message: "main log")
      create(:log_entry, project:, trace_id: "trace-1", message: "sibling log")
      create(:log_entry, project:, trace_id: "other", message: "unrelated log")
      get member_monitoring_log_entry_path(entry)
      expect(response.body).to include("sibling log")
      expect(response.body).not_to include("unrelated log")
    end

    it "correla gli errori della stessa richiesta via colonna trace_id (forma SDK Sentry annidata)" do
      sign_in(owner)
      entry = create(:log_entry, project:, trace_id: "tr-x", message: "log riga")
      group = create(:error_group, project:, title: "ZzzCorrelatedError")
      # trace_id sulla colonna dell'evento e SOLO in contexts.trace nel payload: la vecchia query
      # payload->>'trace_id' non lo trovava; ora la colonna indicizzata sì.
      create(:error_event, group:, project:, trace_id: "tr-x",
                           payload: { "contexts" => { "trace" => { "trace_id" => "tr-x" } } })
      get member_monitoring_log_entry_path(entry)
      expect(response.body).to include("ZzzCorrelatedError")
    end

    # CYRA-345 — Scenario 1 / DoD: dal messaggio con l'identificativo nel testo si arriva agli altri
    # messaggi ed errori della stessa richiesta, con conteggio e link diretto.
    describe "correlazione via trace id (CYRA-345)" do
      def card(body) = Nokogiri::HTML(body).at_css('[data-test="log-request"]')

      it "conta tutte le voci della richiesta (log inclusa la corrente + errori)" do
        sign_in(owner)
        entry = create(:log_entry, project:, trace_id: "tr-count", message: "main")
        create(:log_entry, project:, trace_id: "tr-count", message: "s1")
        create(:log_entry, project:, trace_id: "tr-count", message: "s2")
        group = create(:error_group, project:)
        create(:error_event, group:, project:, trace_id: "tr-count")
        get member_monitoring_log_entry_path(entry)
        count = card(response.body).at_css('[data-test="log-request-count"]').text
        expect(count).to include("3") # 3 log della richiesta (questa + s1 + s2)
        expect(count).to include("1") # 1 errore
      end

      it "offre il link allo stream filtrato per trace + progetto (pivot)" do
        sign_in(owner)
        entry = create(:log_entry, project:, trace_id: "tr-link", message: "main")
        create(:log_entry, project:, trace_id: "tr-link", message: "sibling")
        get member_monitoring_log_entry_path(entry)
        link = card(response.body).at_css('[data-test="log-request-view-all"]')
        params = Rack::Utils.parse_query(URI.parse(link["href"]).query)
        expect(params["trace_id"]).to eq("tr-link")
        expect(params["project_id"]).to eq(project.id)
      end

      it "marca l'identificativo dedotto dal messaggio (provenienza)" do
        sign_in(owner)
        entry = create(:log_entry, project:, trace_id: "tr-x", trace_id_extracted: true,
                                   message: "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom")
        get member_monitoring_log_entry_path(entry)
        expect(card(response.body).at_css('[data-test="log-request-extracted"]')).to be_present
      end

      it "non marca la provenienza quando il trace arriva dal campo strutturato" do
        sign_in(owner)
        entry = create(:log_entry, project:, trace_id: "tr-x", trace_id_extracted: false, message: "boom")
        get member_monitoring_log_entry_path(entry)
        expect(card(response.body).at_css('[data-test="log-request-extracted"]')).to be_nil
      end

      # DoD: quando l'identificativo non c'è, il riquadro spiega perché e cosa serve per averlo.
      it "senza trace id spiega cosa serve per collegare la richiesta" do
        sign_in(owner)
        entry = create(:log_entry, project:, trace_id: nil, message: "riga senza id")
        get member_monitoring_log_entry_path(entry)
        no_trace = card(response.body).at_css('[data-test="log-request-no-trace"]')
        expect(no_trace).to be_present
        expect(no_trace.text.strip).to eq(I18n.t("member.monitoring.logs.show.no_trace"))
      end

      # CYRA-559 — la catena intera, dal messaggio come arriva davvero fino alla pagina. Gli spec di
      # unità provano l'estrazione e quelli qui sopra la resa, ma il difetto viveva nella giuntura:
      # il messaggio d'eccezione di Rails non comincia con il tag (prima c'è la riga vuota di
      # DebugExceptions), il riconoscimento lo mancava, e la pagina accusava il mittente di non
      # averlo mandato mentre era scritto lì. Il trace passa dalla normalizzazione vera, non a mano.
      it "riconosce il codice nel messaggio come arriva da Rails e apre la strada agli altri log" do
        sign_in(owner)
        message = "  \n[e146fed6-1a2b-4c3d-8e4f-556677889900] ActiveRecord::RecordNotFound (Couldn't find User)"
        normalized = Logs::Ingest::Normalize.call(payload: { "message" => message })
        entry = create(:log_entry, project:, message: normalized.message,
                                   trace_id: normalized.trace_id,
                                   trace_id_extracted: normalized.trace_id_extracted)
        create(:log_entry, project:, trace_id: normalized.trace_id, message: "riga successiva della richiesta")

        get member_monitoring_log_entry_path(entry)

        riquadro = card(response.body)
        expect(riquadro.at_css('[data-test="log-request-no-trace"]')).to be_nil
        expect(riquadro.text).to include("riga successiva della richiesta")
        pivot = riquadro.at_css('[data-test="log-request-view-all"]')
        expect(Rack::Utils.parse_query(URI.parse(pivot["href"]).query)["trace_id"])
          .to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
      end
    end

    # CYRA-577 — Scenario 1 / DoD: il titolo era il messaggio INTERO. Su un'eccezione Rails erano
    # quasi tremila caratteri, un titolo alto più di una schermata che spingeva livello, progetto e
    # momento sotto la piega, e per giunta reso come titolo invece che come testo tecnico.
    describe "titolo e messaggio completo (CYRA-577)" do
      let(:trace) { "e146fed6-1a2b-4c3d-8e4f-556677889900" }
      let(:eccezione) do
        "[#{trace}] ActiveRecord::RecordNotFound (Couldn't find User with 'id'=42)\n" \
          "  app/controllers/users_controller.rb:8:in `show'\n#{'  app/frame.rb:1:in `call\'' * 200}"
      end

      def page(body) = Nokogiri::HTML(body)

      it "il titolo è corto: la prima riga, senza il codice della richiesta e senza il backtrace" do
        sign_in(owner)
        entry = create(:log_entry, project:, message: eccezione)

        get member_monitoring_log_entry_path(entry)

        titolo = page(response.body).at_css('[data-test="log-message"]').text.strip
        expect(titolo).to eq("ActiveRecord::RecordNotFound (Couldn't find User with 'id'=42)")
        expect(titolo).not_to include(trace)
        expect(titolo).not_to include("users_controller.rb")
      end

      it "una prima riga lunghissima non diventa un titolo alto una schermata" do
        sign_in(owner)
        entry = create(:log_entry, project:, message: "x" * 2_900)

        get member_monitoring_log_entry_path(entry)

        titolo = page(response.body).at_css('[data-test="log-message"]').text.strip
        expect(titolo.length).to be <= MonitoringHelper::LOG_HEADLINE_MAX
      end

      it "la briciola di pane e il nome della scheda cominciano col nome dell'errore, non col codice" do
        sign_in(owner)
        entry = create(:log_entry, project:, message: eccezione)

        get member_monitoring_log_entry_path(entry)

        documento = page(response.body)
        briciola = documento.css('[data-test="breadcrumb-crumb"]').map { |crumb| crumb.text.strip }.last
        expect(briciola).to start_with("ActiveRecord::RecordNotFound")
        expect(briciola).not_to include(trace)

        scheda = documento.at_css("title").text
        expect(scheda).to start_with("ActiveRecord::RecordNotFound")
        expect(scheda).not_to include(trace)
        expect(scheda).not_to include("users_controller.rb")
      end

      it "il messaggio completo è un blocco tecnico che scorre da solo, sotto le chip" do
        sign_in(owner)
        entry = create(:log_entry, project:, message: eccezione)

        get member_monitoring_log_entry_path(entry)

        documento = page(response.body)
        blocco = documento.at_css('[data-test="log-message-full"]')
        expect(blocco).to be_present
        expect(blocco.text).to include(trace)
        expect(blocco.text).to include("users_controller.rb")
        testo = blocco.at_css("pre")
        expect(testo).to be_present
        expect(testo["class"]).to include("overflow-auto")
        expect(testo["class"]).to match(/max-h-/)
        # Si scorre anche senza mouse: senza tabindex il riquadro non prende il fuoco da tastiera.
        expect(testo["tabindex"]).to eq("0")
        # Sotto le chip: chi apre un registro vede prima livello, progetto e momento.
        expect(response.body.index('data-test="log-meta"')).to be < response.body.index('data-test="log-message-full"')
      end

      it "livello, progetto e momento restano nella prima schermata" do
        sign_in(owner)
        entry = create(:log_entry, project:, level: :error, message: eccezione)

        get member_monitoring_log_entry_path(entry)

        chip = page(response.body).at_css('[data-test="log-meta"]')
        expect(chip.at_css('[data-test="log-level"]')).to be_present
        expect(chip.at_css('[data-test="log-project"]')).to be_present
        expect(chip.at_css('[data-test="log-occurred"]')).to be_present
      end
    end

    # CYRA-345 end-to-end: un log ingerito col solo identificativo nel testo (nessun campo strutturato)
    # diventa correlato agli altri log della richiesta, come promette la guida.
    it "collega i log della richiesta anche col trace id solo nel testo (ingest → show)" do
      sign_in(owner)
      trace = "e146fed6-1a2b-4c3d-8e4f-556677889900"
      Logs::Ingest::Record.call(project:, payload: [
        { "event_id" => "a1", "message" => "[#{trace}] ActiveRecord::RecordNotFound" },
        { "event_id" => "a2", "message" => "[#{trace}] rollback transaction" }
      ])
      entry = project.logs_entries.find_by(event_id: "a1")
      get member_monitoring_log_entry_path(entry)
      expect(response.body).to include("rollback transaction")
      expect(Nokogiri::HTML(response.body).at_css('[data-test="log-request-extracted"]')).to be_present
    end
  end

  describe "error show → logs of this request (correlazione)" do
    it "mostra i log con lo stesso trace_id dell'evento (colonna indicizzata, forma SDK Sentry annidata)" do
      sign_in(owner)
      group = create(:error_group, project:)
      # trace_id sulla colonna (come lo popola Normalize) e SOLO in contexts.trace nel payload:
      # è il caso Sentry-shaped che la vecchia query payload->>'trace_id' perdeva.
      create(:error_event, group:, project:, occurred_at: 1.minute.ago,
                           trace_id: "tr-9", payload: { "contexts" => { "trace" => { "trace_id" => "tr-9" } } })
      create(:log_entry, project:, trace_id: "tr-9", message: "request log line")
      get member_monitoring_error_group_path(group)
      expect(response.body).to include("request log line")
    end
  end
  # CYRA-350 — il filtro offriva cinque livelli anche quando due non avevano nemmeno una voce, e
  # sceglierli portava su una pagina che diceva solo «nessun risultato», senza uscita.
  describe "il filtro dei livelli" do
    before do
      allow_n_plus_one do
        create(:log_entry, project:, level: "error", message: "rotto")
        create(:log_entry, project:, level: "warning", message: "attento")
      end
      sign_in(owner)
    end

    it "ogni livello dice quante voci ha" do
      get member_monitoring_log_entries_path

      options = Nokogiri::HTML(response.body).css('select#level option')
      labels = options.map(&:text)
      expect(labels.find { |l| l.start_with?("Error") }).to include("(1)")
      expect(labels.find { |l| l.start_with?("Info") }).to include("(0)")
    end

    it "i livelli senza voci non sono selezionabili" do
      get member_monitoring_log_entries_path

      options = Nokogiri::HTML(response.body).css('select#level option')
      vuoto = options.find { |o| o["value"] == "info" }
      pieno = options.find { |o| o["value"] == "error" }
      expect(vuoto["disabled"]).to eq("disabled")
      expect(pieno["disabled"]).to be_nil
    end

    it "senza risultati offre la via d'uscita, la causa probabile e la guida" do
      get member_monitoring_log_entries_path(level: [ "debug" ])

      expect(response.body).to include('data-test="logs-clear-filters"')
      expect(response.body).to include('data-test="logs-no-match-level"')
      expect(response.body).to include('data-test="logs-open-guide"')
      expect(response.body).to include(member_guides_logs_path)
    end

    it "il pulsante di uscita porta all'elenco senza filtri" do
      get member_monitoring_log_entries_path(level: [ "debug" ], q: "niente")

      link = Nokogiri::HTML(response.body).at_css('[data-test="logs-clear-filters"]')
      # CYRA-694 — il marker ft=1 fa dimenticare anche i filtri ricordati in sessione.
      expect(link["href"]).to eq(member_monitoring_log_entries_path(ft: "1"))
    end
  end
end
