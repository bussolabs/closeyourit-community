# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::MetricGroups", type: :request do
  let(:org) { create(:organization) }
  # Gli attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune li faceva pagare tutti a tutti.
  let(:owner) { account_with_membership(:owner) }
  let(:admin) { account_with_membership(:admin) }
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
      get member_monitoring_metric_groups_path
      expect(response).to redirect_to(login_path)
    end

    it "admin → 200 e vede i gruppi dell'org" do
      sign_in(owner)
      create(:metric_group, project:, title: "SELECT * FROM widgets")
      get member_monitoring_metric_groups_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("SELECT * FROM widgets")
    end

    it "member assegnato vede i gruppi del progetto, non di un progetto non assegnato (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      create(:metric_group, project:, title: "VisibleQuery")
      create(:metric_group, project: create(:project, organization: org), title: "HiddenQuery")
      get member_monitoring_metric_groups_path
      expect(response.body).to include("VisibleQuery")
      expect(response.body).not_to include("HiddenQuery")
    end

    it "member senza assegnazioni → nessun gruppo (strict)" do
      sign_in(member)
      create(:metric_group, project:, title: "SomeQuery")
      get member_monitoring_metric_groups_path
      expect(response.body).not_to include("SomeQuery")
    end

    it "la media sopra il secondo si legge in unità umane e «ultima» resta su una riga" do
      sign_in(owner)
      group = create(:metric_group, project:, samples_count: 1, duration_total_ms: 974_203.0)

      get member_monitoring_metric_groups_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='metric-group-avg-#{group.id}']").text.strip).to eq("16.2min")
      expect(doc.at_css("[data-test='metric-group-last-seen-#{group.id}']")["class"]).to include("whitespace-nowrap")
    end

    it "filtra per kind" do
      sign_in(owner)
      create(:metric_group, project:, kind: :slow_query, title: "QueryOne")
      create(:metric_group, :slow_method, project:, title: "MethodOne")
      get member_monitoring_metric_groups_path, params: { kind: [ "slow_method" ] }
      expect(response.body).to include("MethodOne")
      expect(response.body).not_to include("QueryOne")
    end

    it "mostra sia le metriche raw sia i verdetti performance_issue (corsie unite)" do
      sign_in(owner)
      create(:metric_group, project:, kind: :slow_query, title: "RawSlowQuery")
      create(:metric_group, :performance_issue, project:, fingerprint: "pi-1", title: "N+1 on Order#items")
      get member_monitoring_metric_groups_path
      expect(response.body).to include("RawSlowQuery")
      expect(response.body).to include("N+1 on Order#items")
    end

    it "filtra per subtype (verdetti performance_issue)" do
      sign_in(owner)
      create(:metric_group, :performance_issue, project:, subtype: "n_plus_one", fingerprint: "pi-npo", title: "NPlusOneIssue")
      create(:metric_group, :performance_issue, project:, subtype: "slow_request", fingerprint: "pi-sr", title: "SlowRequestIssue")
      get member_monitoring_metric_groups_path, params: { subtype: [ "slow_request" ] }
      expect(response.body).to include("SlowRequestIssue")
      expect(response.body).not_to include("NPlusOneIssue")
    end

    it "filtra per progetto" do
      sign_in(owner)
      other = create(:project, organization: org)
      create(:metric_group, project:, title: "ThisProject")
      create(:metric_group, project: other, title: "OtherProject")
      get member_monitoring_metric_groups_path, params: { project_id: [ project.id ] }
      expect(response.body).to include("ThisProject")
      expect(response.body).not_to include("OtherProject")
    end

    it "search per titolo (signature)" do
      sign_in(owner)
      create(:metric_group, project:, title: "Searchable")
      create(:metric_group, project:, title: "HiddenTitle")
      get member_monitoring_metric_groups_path, params: { q: "Searchable" }
      expect(response.body).to include("Searchable")
      expect(response.body).not_to include("HiddenTitle")
    end

    it "con open=1 mostra solo i gruppi non ancora promossi a ticket (deep-link KPI 'perf issue')" do
      sign_in(owner)
      create(:metric_group, :performance_issue, project:, fingerprint: "pi-open", title: "OpenPerf")
      create(:metric_group, :performance_issue, project:, fingerprint: "pi-done", title: "PromotedPerf",
                                                 ticket: create(:ticket, organization: org, project: project))
      get member_monitoring_metric_groups_path, params: { open: "1" }
      expect(response.body).to include("OpenPerf")
      expect(response.body).not_to include("PromotedPerf")
    end

    # CYRA-339 scenario 1: senza sort esplicito la lista mette in cima il costo complessivo (durata
    # totale = media × occorrenze), non la media. Il collo di bottiglia vero (tante occorrenze) batte
    # il picco raro capitato una o due volte.
    it "ordina per default dal costo complessivo più alto, non dalla media" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "rare", title: "RareSpike",
                            samples_count: 2, duration_total_ms: 2_000.0)
      create(:metric_group, project:, fingerprint: "bottleneck", title: "RealBottleneck",
                            samples_count: 100_000, duration_total_ms: 81_000_000.0)
      get member_monitoring_metric_groups_path
      expect(response.body.index("RealBottleneck")).to be < response.body.index("RareSpike")
    end

    # CYRA-339: il tempo totale speso è una colonna della tabella, ordinabile.
    it "espone la colonna 'tempo totale' ordinabile" do
      sign_in(owner)
      create(:metric_group, project:, title: "SomeGroup")
      get member_monitoring_metric_groups_path
      expect(response.body).to include('data-test="sort-total_duration"')
    end

    it "ordina esplicitamente per tempo totale crescente quando richiesto (?sort=total_duration)" do
      sign_in(owner)
      create(:metric_group, project:, fingerprint: "cheap", title: "CheapOp", duration_total_ms: 100.0)
      create(:metric_group, project:, fingerprint: "pricey", title: "PriceyOp", duration_total_ms: 900_000.0)
      get member_monitoring_metric_groups_path, params: { sort: "total_duration" }
      expect(response.body.index("CheapOp")).to be < response.body.index("PriceyOp")
    end

    # CYRA-339 scenario 1: le righe con meno di 20 casi sono marcate come poco significative.
    it "marca «pochi campioni» le righe sotto i 20 casi, non le altre" do
      sign_in(owner)
      few = create(:metric_group, project:, fingerprint: "few", title: "FewSamples",
                                  samples_count: 3, duration_total_ms: 3_000.0)
      many = create(:metric_group, project:, fingerprint: "many", title: "ManySamples",
                                   samples_count: 500, duration_total_ms: 5_000.0)
      get member_monitoring_metric_groups_path
      expect(response.body).to include(%(data-test="metric-low-sample-#{few.id}"))
      expect(response.body).not_to include(%(data-test="metric-low-sample-#{many.id}"))
    end

    # CYRA-339 scenario 2: il riquadro in alto non promuove più la media più alta (distorta da 1-2
    # casi) ma il tempo totale speso.
    it "il riquadro in alto mostra il tempo totale, non la media più alta" do
      sign_in(owner)
      create(:metric_group, project:, samples_count: 2, duration_total_ms: 2_000.0)
      get member_monitoring_metric_groups_path
      expect(response.body).to include('data-test="stat-total-duration"')
      expect(response.body).not_to include('data-test="stat-slowest-avg"')
    end

    # CYRA-342: i due filtri della toolbar (kind = «Categoria», subtype = «Tipo di problema») non
    # devono più condividere lo stesso nome. Nomi accessibili distinti sul campo (aria-label del
    # select) e sul pulsante «Rimuovi filtro», così anche un lettore di schermo annuncia due campi
    # diversi. I nomi dei parametri URL (kind/subtype) restano invariati (link salvati stabili).
    context "filtri disambiguati (CYRA-342)" do
      it "i due filtri hanno nomi accessibili distinti su campo e pulsante di rimozione (en)" do
        sign_in(owner)
        create(:metric_group, project:, title: "AnyQuery")
        get member_monitoring_metric_groups_path
        expect(response.body).to include('aria-label="Category"')
        expect(response.body).to include('aria-label="Problem type"')
        expect(response.body).to include("Remove Category filter")
        expect(response.body).to include("Remove Problem type filter")
      end

      it "in italiano i due filtri non si chiamano più entrambi «Tipo»" do
        owner.update!(locale: "it")
        sign_in(owner)
        create(:metric_group, project:, title: "AnyQuery")
        get member_monitoring_metric_groups_path
        expect(response.body).to include('aria-label="Categoria"')
        expect(response.body).to include('aria-label="Tipo di problema"')
        expect(response.body).to include("Rimuovi filtro Categoria")
        expect(response.body).to include("Rimuovi filtro Tipo di problema")
        # Il nome ambiguo «Tipo» secco (uguale per due filtri diversi) non deve più comparire.
        expect(response.body).not_to include('Rimuovi filtro Tipo"')
      end

      # I parametri URL non cambiano: il rename è solo di etichetta, i filtri restano funzionanti.
      it "il parametro URL resta `kind`/`subtype` (link salvati non si rompono)" do
        sign_in(owner)
        create(:metric_group, project:, kind: :slow_method, title: "MethodStable")
        create(:metric_group, project:, kind: :slow_query, title: "QueryStable")
        get member_monitoring_metric_groups_path, params: { kind: [ "slow_method" ] }
        expect(response.body).to include("MethodStable")
        expect(response.body).not_to include("QueryStable")
      end
    end
  end

  describe "GET show" do
    it "admin → 200 con signature e occorrenza recente" do
      sign_in(owner)
      group = create(:metric_group, project:, title: "SELECT * FROM line_items WHERE order_id = ?")
      create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, duration_ms: 1200)
      get member_monitoring_metric_group_path(group)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("SELECT * FROM line_items WHERE order_id = ?")
    end

    # CYRA-146: la pagina di dettaglio mostra p50/p95/p99 oltre alla media, così i casi lenti che la
    # media nasconde sono visibili (chip header + riga nel pannello dettagli).
    it "mostra i percentili p50/p95/p99 di durata (casi peggiori oltre la media)" do
      sign_in(owner)
      group = create(:metric_group, project:, title: "SELECT * FROM heavy")
      create(:metric_sample, group:, project:, duration_ms: 20)
      create(:metric_sample, group:, project:, duration_ms: 20)
      create(:metric_sample, group:, project:, duration_ms: 5000)

      get member_monitoring_metric_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="stat-percentiles"')
      expect(response.body).to include('data-test="detail-percentiles"')
      expect(response.body).to include("p50")
      expect(response.body).to include("p95")
      expect(response.body).to include("p99")
    end

    it "senza campioni la sezione percentili è presente (valori non calcolabili)" do
      sign_in(owner)
      group = create(:metric_group, project:, title: "SELECT * FROM cold")

      get member_monitoring_metric_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="stat-percentiles"')
      expect(response.body).to include('data-test="detail-percentiles"')
    end

    # CYRA-570 — su un gruppo senza campioni nel periodo i due grafici disegnavano trenta barrette
    # identiche: sembravano misure piccole, erano misure assenti. Adesso lo dicono a parole.
    it "senza campioni nel periodo i due grafici dichiarano di non avere dati" do
      sign_in(owner)
      group = create(:metric_group, project:, title: "SELECT * FROM frozen")

      get member_monitoring_metric_group_path(group)

      expect(response.body).to include('data-test="duration-buckets-empty"')
      expect(response.body).to include('data-test="duration-trend-buckets-empty"')
      expect(response.body).to include(I18n.t("member.metrics.chart_empty"))
      expect(response.body).to include(I18n.t("member.metrics.duration_chart_empty"))
      expect(response.body).not_to include('data-test="duration-buckets"')
    end

    it "non ripete i metadati dell'occorrenza nel pannello query: environment reso una sola volta + footer presente (CYRA-19)" do
      sign_in(owner)
      group = create(:metric_group, project:, title: "SELECT * FROM carts WHERE id = ?")
      create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, duration_ms: 369, environment: "cyra19env")
      get member_monitoring_metric_group_path(group)

      expect(response).to have_http_status(:ok)
      # L'environment dell'occorrenza è reso una sola volta (badge nella tabella occorrenze),
      # non più duplicato nel chip metadati del pannello query.
      expect(response.body.scan("cyra19env").size).to eq(1)
      # Il footer con occurred_at/sample resta nel pannello occorrenza.
      expect(response.body).to include('data-test="occurrence-footer"')
    end

    it "rende la sezione SDK come 'nome versione' leggibile, non l'Hash grezzo (CYRA-20)" do
      sign_in(owner)
      group = create(:metric_group, project:, title: "SELECT * FROM orders WHERE id = ?")
      create(:metric_sample, group:, project:, occurred_at: 1.minute.ago,
             payload: { "sql" => "SELECT 1", "sdk" => { "name" => "closeyourit-ruby", "version" => "0.4.0" } })
      get member_monitoring_metric_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("closeyourit-ruby 0.4.0")
      # Nessun Hash Ruby grezzo: le virgolette escaped attorno alle chiavi comparirebbero solo se stampato via to_s.
      expect(response.body).not_to include("&quot;name&quot;")
    end

    # CYRA-342: nella card «Dettagli» di un verdetto performance_issue le due righe prima etichettate
    # entrambe «Tipo» (categoria + sottotipo) diventano UNA sola riga gerarchica «categoria › tipo»,
    # così i due valori non appaiono più come campi omonimi affiancati.
    context "card Dettagli disambiguata (CYRA-342)" do
      def sign_in_it
        owner.update!(locale: "it")
        sign_in(owner)
      end

      it "performance_issue → un'unica riga gerarchica «Problema di performance › Query N+1»" do
        sign_in_it
        group = create(:metric_group, :performance_issue, project:, subtype: "n_plus_one", title: "N+1 SELECT users")
        get member_monitoring_metric_group_path(group)

        expect(response).to have_http_status(:ok)
        # Una sola riga (data-test) che porta la gerarchia categoria › tipo, non due campi omonimi.
        classification = Nokogiri::HTML(response.body).css("[data-test='detail-classification']")
        expect(classification.size).to eq(1)
        expect(classification.text).to include("Problema di performance › Query N+1")
      end

      it "metrica raw (non performance_issue) → la Categoria è leggibile, non il valore grezzo" do
        sign_in_it
        group = create(:metric_group, project:, kind: :slow_query, title: "SELECT * FROM t")
        get member_monitoring_metric_group_path(group)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Query lenta")
        expect(response.body).not_to include("Problema di performance ›")
      end
    end

    it "gruppo di un progetto non visibile → 404 (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      foreign = create(:metric_group, project: create(:project, organization: org))
      get member_monitoring_metric_group_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "accetta un range valido per il chart" do
      sign_in(owner)
      group = create(:metric_group, project:)
      get member_monitoring_metric_group_path(group, range: "7d")
      expect(response).to have_http_status(:ok)
    end

    it "performance_issue → correla log della stessa richiesta via trace_id" do
      sign_in(owner)
      group = create(:metric_group, :performance_issue, project:, title: "N+1 SELECT users")
      create(:metric_sample, group:, project:, kind: :performance_issue,
             subtype: "n_plus_one", trace_id: "req-777", occurred_at: 1.minute.ago, duration_ms: 320)
      create(:log_entry, project:, trace_id: "req-777", message: "CorrelatedLogLine")
      get member_monitoring_metric_group_path(group)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("CorrelatedLogLine")
    end

    # CYRA-53: correlazione ERRORI della stessa richiesta (trace_id), speculare ai log. Errori con
    # altro trace o di altro progetto NON compaiono (isolamento tenant).
    it "performance_issue → correla gli errori della stessa richiesta via trace_id, escludendo altro trace/progetto" do
      sign_in(owner)
      group = create(:metric_group, :performance_issue, project:, title: "N+1 SELECT orders")
      create(:metric_sample, group:, project:, kind: :performance_issue,
             subtype: "n_plus_one", trace_id: "req-corr", occurred_at: 1.minute.ago, duration_ms: 300)
      correlated = create(:error_event, project:, group: create(:error_group, project:, title: "CorrelatedError"), trace_id: "req-corr")
      other_trace = create(:error_event, project:, group: create(:error_group, project:, title: "OtherTraceError"), trace_id: "req-zzz")
      other_project = create(:project, organization: org)
      foreign = create(:error_event, project: other_project,
                       group: create(:error_group, project: other_project, title: "ForeignProjectError"), trace_id: "req-corr")

      get member_monitoring_metric_group_path(group)

      expect(response.body).to include(%(data-test="trace-error-#{correlated.id}"))
      expect(response.body).not_to include(%(data-test="trace-error-#{other_trace.id}"))
      expect(response.body).not_to include(%(data-test="trace-error-#{foreign.id}"))
    end

    # CYRA-53: senza ORDER esplicito i (fino a 50) errori correlati cambiano ordine ad ogni refresh.
    # Inseriti in ordine occurred_at CRESCENTE, devono comparire in DESC (più recente in cima).
    it "ordina gli errori correlati per occurred_at desc (deterministico, non ordine d'inserimento)" do
      sign_in(owner)
      group = create(:metric_group, :performance_issue, project:, title: "N+1 SELECT users")
      create(:metric_sample, group:, project:, kind: :performance_issue,
             subtype: "n_plus_one", trace_id: "req-order", occurred_at: 1.minute.ago, duration_ms: 300)
      eg = create(:error_group, project:, title: "OrderedError")
      old = create(:error_event, project:, group: eg, trace_id: "req-order", occurred_at: 3.hours.ago)
      mid = create(:error_event, project:, group: eg, trace_id: "req-order", occurred_at: 2.hours.ago)
      recent = create(:error_event, project:, group: eg, trace_id: "req-order", occurred_at: 1.hour.ago)

      get member_monitoring_metric_group_path(group)

      positions = [ recent, mid, old ].map { |event| response.body.index(%(data-test="trace-error-#{event.id}")) }
      expect(positions).to all(be_present)
      expect(positions).to eq(positions.sort) # recent prima di mid prima di old = desc per occurred_at
    end

    # CYRA-53 (review Codex): a parità di occurred_at il solo order(occurred_at) non è deterministico e
    # il limit(50) selezionerebbe/ordinerebbe le righe arbitrariamente. Tie-breaker stabile id: :desc.
    it "a parità di occurred_at usa id desc come tie-breaker (ordine stabile, no selezione arbitraria)" do
      sign_in(owner)
      group = create(:metric_group, :performance_issue, project:, title: "N+1 tie")
      create(:metric_sample, group:, project:, kind: :performance_issue,
             subtype: "n_plus_one", trace_id: "req-tie", occurred_at: 1.minute.ago, duration_ms: 300)
      eg = create(:error_group, project:, title: "TieError")
      same = 2.hours.ago
      create_list(:error_event, 4, project:, group: eg, trace_id: "req-tie", occurred_at: same)
      expected = Errors::Event.where(project_id: project.id, trace_id: "req-tie").order(id: :desc).pluck(:id)

      get member_monitoring_metric_group_path(group)

      positions = expected.map { |eid| response.body.index(%(data-test="trace-error-#{eid}")) }
      expect(positions).to all(be_present)
      expect(positions).to eq(positions.sort) # HTML nell'ordine id desc a parità di timestamp
    end

    it "limita le occorrenze a una pagina (#{Monitoring::Constants::OCCURRENCES_PER_PAGE}) e pagina le restanti" do
      sign_in(owner)
      group = create(:metric_group, project:)
      per = Monitoring::Constants::OCCURRENCES_PER_PAGE
      (per + 2).times { |i| create(:metric_sample, group:, project:, occurred_at: (i + 1).minutes.ago) }
      chart_at = Time.current.iso8601(6)

      get member_monitoring_metric_group_path(group, chart_at:)
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(per)
      expect(response.body).to include('data-test="pagination-next"')
      expect(Nokogiri::HTML(response.body).at_css("[data-test='pagination-next']")["href"]).to include("chart_at=")

      get member_monitoring_metric_group_path(group, page: 2)
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(2)
    end

    # CYRA-46: drill-down dall'istogramma delle metriche, speculare agli errori.
    it "drill-down: from/to filtrano i campioni alla finestra del blocco e mostrano il chip di reset" do
      sign_in(owner)
      group = create(:metric_group, project:)
      create(:metric_sample, group:, project:, occurred_at: 3.days.ago, duration_ms: 999)
      3.times { create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, duration_ms: 12) }

      get member_monitoring_metric_group_path(group, from: (3.days.ago - 1.hour).iso8601, to: (3.days.ago + 1.hour).iso8601)

      expect(response).to have_http_status(:ok)
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(1)
      expect(response.body).to include('data-test="bucket-filter"')
    end

    it "from/to malformati → ignorati, tutti i campioni, nessun chip" do
      sign_in(owner)
      group = create(:metric_group, project:)
      2.times { create(:metric_sample, group:, project:, occurred_at: 1.minute.ago) }

      get member_monitoring_metric_group_path(group, from: "boh", to: "boh")

      expect(response.body.scan('data-test="occurrence-row"').size).to eq(2)
      expect(response.body).not_to include('data-test="bucket-filter"')
    end

    it "l'istogramma espone barre cliccabili con from/to per il drill-down" do
      sign_in(owner)
      group = create(:metric_group, project:)
      create(:metric_sample, group:, project:, occurred_at: 1.minute.ago)

      get member_monitoring_metric_group_path(group)

      expect(response.body).to include('data-test="bucket-link"')
      expect(response.body).to match(/<a href="[^"]*from=[^"]*"[^>]*data-test="bucket-link"/)
    end

    it "mantiene conteggio e campioni coerenti quando il tempo avanza tra rendering e click" do
      sign_in(owner)
      group = create(:metric_group, project:)
      now = Time.zone.parse("2026-07-12 20:53:32.900000")
      bucket_to = now - 10.hours

      travel_to(now, with_usec: true)
      create(:metric_sample, group:, project:, occurred_at: bucket_to - 0.1.seconds)
      get member_monitoring_metric_group_path(group, range: "24h")

      href = Nokogiri::HTML(response.body).at_css("a[data-test='bucket-link']")["href"]
      expect(href).to include("chart_at=")

      create(:metric_sample, group:, project:, occurred_at: bucket_to + 1.second)
      travel_to(now + 3.seconds, with_usec: true)
      get href

      doc = Nokogiri::HTML(response.body)
      active = doc.at_css("a[data-test='bucket-link'].ring-2")
      expect(response.body.scan('data-test="occurrence-row"').size).to eq(1)
      expect(active["data-value"]).to end_with("· 1 occ")
    end

    it "applica la finestra half-open con precisione al microsecondo" do
      sign_in(owner)
      group = create(:metric_group, project:)
      from = Time.zone.parse("2026-07-12 10:23:32.123456")
      to = from + 30.minutes
      create(:metric_sample, group:, project:, occurred_at: from - 0.000001.seconds)
      create(:metric_sample, group:, project:, occurred_at: from)
      create(:metric_sample, group:, project:, occurred_at: to - 0.000001.seconds)
      create(:metric_sample, group:, project:, occurred_at: to)

      get member_monitoring_metric_group_path(group, from: from.iso8601(6), to: to.iso8601(6))

      expect(response.body.scan('data-test="occurrence-row"').size).to eq(2)
    end
  end

  describe "promote" do
    let(:group) { create(:metric_group, project:, title: "SELECT * FROM users WHERE id = ?") }

    it "admin → crea ticket e collega il gruppo" do
      sign_in(owner)
      expect { post promote_member_monitoring_metric_group_path(group) }.to change(Ticketing::Ticket, :count).by(1)
      expect(group.reload).to be_promoted
      expect(response).to redirect_to(member_monitoring_metric_group_path(group))
    end

    it "gruppo già promosso → alert, nessun secondo ticket" do
      sign_in(owner)
      post promote_member_monitoring_metric_group_path(group)
      expect { post promote_member_monitoring_metric_group_path(group) }.not_to change(Ticketing::Ticket, :count)
      expect(flash[:alert]).to be_present
    end

    it "member semplice → forbidden (redirect root)" do
      sign_in(member)
      create(:project_membership, account: member, project: project)
      expect { post promote_member_monitoring_metric_group_path(group) }.not_to change(Ticketing::Ticket, :count)
      expect(response).to redirect_to(root_path)
    end

    it "non autenticato → redirect login" do
      expect { post promote_member_monitoring_metric_group_path(group) }.not_to change(Ticketing::Ticket, :count)
      expect(response).to redirect_to(login_path)
    end

    it "performance_issue → crea ticket e collega il gruppo" do
      sign_in(owner)
      pi = create(:metric_group, :performance_issue, project:, title: "N+1 SELECT line_items")
      expect { post promote_member_monitoring_metric_group_path(pi) }.to change(Ticketing::Ticket, :count).by(1)
      expect(pi.reload).to be_promoted
    end
  end
  # CYRA-351 — a larghezza di uno schermo comune la tabella si interrompeva poco dopo metà: fuori
  # restavano proprio le colonne che rendono interpretabili le altre.
  describe "la tabella delle performance" do
    before { sign_in(owner) }

    it "mette prima le colonne che rendono leggibili i numeri, e il picco massimo per ultimo" do
      create(:metric_group, project:, title: "SELECT * FROM x")

      get member_monitoring_metric_groups_path

      headers = Nokogiri::HTML(response.body).css("thead th").map { |th| th.text.strip }
      occorrenze = headers.index { |h| h.include?(I18n.t("member.metrics.col_occurrences")) }
      ultima = headers.index { |h| h.include?(I18n.t("member.metrics.col_last_seen")) }
      ticket = headers.index { |h| h.include?(I18n.t("member.metrics.col_ticket")) }
      massimo = headers.index { |h| h.include?(I18n.t("member.metrics.col_max")) }

      expect([ occorrenze, ultima, ticket ]).to all(be < massimo)
    end

    it "la prima colonna ha larghezza fissa e porta il testo intero nel tooltip" do
      lunga = "SELECT #{'colonna, ' * 40} FROM tabella"
      group = create(:metric_group, project:, title: lunga)

      get member_monitoring_metric_groups_path

      link = Nokogiri::HTML(response.body).at_css(%([data-test="metric-group-link-#{group.id}"]))
      expect(link["class"]).to include("truncate", "max-w-[17rem]")
      expect(link["title"]).to be_present
    end

    it "il contenitore dichiara quando resta contenuto fuori schermo" do
      create(:metric_group, project:)

      get member_monitoring_metric_groups_path

      # Da CYRA-661 il controller sta sul contenitore ESTERNO, che avvolge lo scroller e ospita il
      # cartellino «scorri»: l'elemento con overflow-x è quello interno, e su di lui il controller non
      # c'è più. Stessa forma che asserisce spec/components/ui/table_component_spec.rb:36.
      scroller = Nokogiri::HTML(response.body).css(".overflow-x-auto").find { |node| node.at_css("table") }
      expect(scroller["data-ui--scroll-hint-target"]).to eq("scroller")
      expect(scroller.parent["data-controller"].to_s).to include("ui--scroll-hint")
    end

    # CYRA-670 — su una tabella larga chi usa lo screen reader sente il numero della cella senza mai
    # sentire il nome della colonna: `scope="col"` è quello che lega i due.
    it "ogni intestazione dichiara la colonna che sta intestando" do
      create(:metric_group, project:)

      get member_monitoring_metric_groups_path

      # Solo le intestazioni rese da HeaderComponent: la prima colonna è la casella «seleziona
      # tutto», un <th> scritto a mano nella view che non intesta nessun dato.
      intestazioni = Nokogiri::HTML(response.body).css("thead th.font-mono")
      expect(intestazioni).not_to be_empty
      expect(intestazioni.map { |th| th["scope"] }.uniq).to eq([ "col" ])
    end
  end
  # CYRA-352 — in cima un totale, sotto lo stesso totale, e l'elenco dichiarava una quantità
  # diversa: due numeri per la stessa cosa nella stessa schermata.
  describe "i due conteggi della scheda" do
    before { sign_in(owner) }

    it "distingue le occorrenze totali dai campioni ancora conservati" do
      group = create(:metric_group, project:, samples_count: 1_000)
      create(:metric_sample, group:, project:)

      get member_monitoring_metric_group_path(group)

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="stat-occurrences"]').text).to include(I18n.t("member.metrics.stat_occurrences_total").downcase)
      expect(html.at_css('[data-test="occurrences-kept"]').text).to include(I18n.t("member.metrics.occurrences_kept", count: 1))
    end

    it "spiega perché il secondo numero è più basso" do
      group = create(:metric_group, project:, samples_count: 1_000)
      create(:metric_sample, group:, project:)

      get member_monitoring_metric_group_path(group)

      expect(response.body).to include('data-test="occurrences-retention-note"')
      nota = Nokogiri::HTML(response.body).at_css('[data-test="occurrences-retention-note"]').text
      expect(nota).to include("1.000").or include("1,000")
      expect(nota).to include(Metrics::Retention.for(project).to_s)
    end

    it "quando i due numeri coincidono non spiega niente" do
      group = create(:metric_group, project:, samples_count: 1)
      create(:metric_sample, group:, project:)

      get member_monitoring_metric_group_path(group)

      expect(response.body).not_to include('data-test="occurrences-retention-note"')
    end
  end
end
