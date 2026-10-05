# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member performance monitoring", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  before { Types::InstallDefaults.call(organization: org) }

  it "la voce nav Performance porta alla lista dei gruppi-metrica" do
    create(:metric_group, project:, title: "SELECT * FROM line_items WHERE order_id = ?")
    sign_in_as(admin_account)

    visit member_monitoring_error_groups_path
    click_on_test "member-nav-performance"

    expect_test "member-metric-groups"
    expect_test "metric-group-row"
    expect(page).to have_text("SELECT * FROM line_items WHERE order_id = ?")
  end

  it "stato vuoto quando non ci sono gruppi visibili" do
    sign_in_as(admin_account)
    visit member_monitoring_metric_groups_path

    expect_test "metrics-empty"
  end

  it "naviga dalla lista al dettaglio del gruppo-metrica" do
    group = create(:metric_group, project:, title: "SELECT * FROM line_items WHERE order_id = ?")
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, duration_ms: 1200, environment: "production")
    sign_in_as(admin_account)

    visit member_monitoring_metric_groups_path
    find("[data-test='metric-group-link-#{group.id}']").click

    expect_test "member-metric-group"
    expect(page).to have_text("SELECT * FROM line_items WHERE order_id = ?")
    expect_test "occurrence-row"
  end

  it "pagina le occorrenze (max per pagina) e naviga con il pager" do
    group = create(:metric_group, project:, title: "SELECT * FROM line_items WHERE order_id = ?")
    per = Monitoring::Constants::OCCURRENCES_PER_PAGE
    (per + 3).times { |i| create(:metric_sample, group:, project:, occurred_at: (i + 1).minutes.ago) }
    sign_in_as(admin_account)

    visit member_monitoring_metric_group_path(group)
    expect(page).to have_css("[data-test='occurrence-row']", count: per)
    expect_test "metric-samples-pagination"

    click_on_test "pagination-next"
    expect(page).to have_css("[data-test='occurrence-row']", count: 3)
  end

  # CYRA-46: drill-down dall'istogramma anche per le metriche.
  it "drill-down: cliccare la barra dell'istogramma filtra i campioni al suo blocco temporale" do
    freeze_time do
      group = create(:metric_group, project:, title: "SELECT * FROM orders WHERE id = ?")
      create(:metric_sample, group:, project:, occurred_at: 3.days.ago + 1.hour, duration_ms: 950)
      (Monitoring::Constants::OCCURRENCES_PER_PAGE + 3).times do |i|
        create(:metric_sample, group:, project:, occurred_at: (i + 1).minutes.ago, duration_ms: 20)
      end
      sign_in_as(admin_account)

      visit member_monitoring_metric_group_path(group, range: "7d")
      expect(page).to have_css("[data-test='occurrence-row']", count: Monitoring::Constants::OCCURRENCES_PER_PAGE)
      expect(page).to have_css("a[data-test='bucket-link']", minimum: 2)

      first("a[data-test='bucket-link']").click

      expect_test "bucket-filter"
      expect(page).to have_css("[data-test='occurrence-row']", count: 1)

      click_on_test "bucket-filter-clear"
      expect(page).not_to have_css("[data-test='bucket-filter']")
    end
  end

  it "mostra i parametri dell'occorrenza selezionata quando la cattura è attiva" do
    group = create(:metric_group, project:, title: "SELECT * FROM orders WHERE id = ?")
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, duration_ms: 1500,
                           payload: { "sql" => "SELECT * FROM orders WHERE id = ?",
                                      "bindings" => [ { "name" => "id", "value" => "8842" } ],
                                      "source" => "app/models/order.rb:42", "db_system" => "postgresql" })
    sign_in_as(admin_account)

    visit member_monitoring_metric_group_path(group)

    expect(page).to have_text("8842")
    expect(page).to have_text("app/models/order.rb:42")
  end

  # CYRA-353 — il messaggio identificava ciò che manca e poi abbandonava chi legge nel punto di
  # massima intenzione: «attivala nella gemma», senza dire quale riga scrivere né dove.
  it "quando la cattura dei parametri è spenta dice la riga esatta, l'avvertenza e la guida" do
    group = create(:metric_group, project:, title: "SELECT 1")
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago) # payload default senza bindings

    sign_in_as(admin_account)
    visit member_monitoring_metric_group_path(group)

    expect_test "parameters-off"
    expect(page).to have_text("c.capture_bind_params = true")
    # I valori raccolti possono contenere dati personali: dirlo PRIMA, non dopo.
    expect_test "parameters-privacy"
    expect(page).to have_css("[data-test='parameters-guide'][href='#{member_guides_performance_path}']")
  end

  # Una riga con un trattino non dice «vuoto»: dice «manca qualcosa e non so cosa».
  it "le voci senza valore non si mostrano al posto di un trattino" do
    group = create(:metric_group, project:, title: "SELECT 1")
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago)

    sign_in_as(admin_account)
    visit member_monitoring_metric_group_path(group)

    expect(page).to have_no_css("[data-test='detail-sdk']")
    expect(page).to have_no_css("[data-test='detail-db-system']")
  end

  it "la sezione query dell'occorrenza non ripete i metadati ridondanti: restano nel footer e nella pagina (CYRA-19)" do
    group = create(:metric_group, project:, title: "SELECT * FROM carts WHERE id = ?")
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, duration_ms: 369, environment: "cyra19env")
    sign_in_as(admin_account)

    visit member_monitoring_metric_group_path(group)

    # Il chip metadati ridondante (tempo fa · durata · environment) non è più nel pannello query…
    within "[data-test='occurrence-panel']" do
      expect(page).not_to have_text("cyra19env")
      expect(page).to have_css("[data-test='occurrence-footer']")
    end
    # …ma l'informazione resta visibile altrove nella show (tabella occorrenze + card Dettagli)
    expect(page).to have_text("cyra19env")
    expect_test "metric-details"
  end

  it "un admin promuove una metrica a ticket dal dettaglio" do
    group = create(:metric_group, project:, title: "SELECT * FROM users WHERE id = ?")
    sign_in_as(admin_account)
    visit member_monitoring_metric_group_path(group)

    click_on_test "promote-ticket"

    expect_test "flash-notice"
    expect(group.reload).to be_promoted
    expect(project.tickets.count).to eq(1)
  end

  it "un member assegnato vede il dettaglio in sola lettura (niente promote)" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    group = create(:metric_group, project:)
    sign_in_as(member)

    visit member_monitoring_metric_group_path(group)

    expect_test "member-metric-group"
    expect(page).not_to have_css("[data-test='promote-ticket']")
  end

  it "la lista unita include sia le metriche raw sia i verdetti performance_issue" do
    create(:metric_group, project:, kind: :slow_query, title: "RawSlowQuery")
    create(:metric_group, :performance_issue, project:, fingerprint: "pi-x", title: "N+1 on Order#items")
    sign_in_as(admin_account)

    visit member_monitoring_metric_groups_path

    expect(page).to have_text("RawSlowQuery")
    expect(page).to have_text("N+1 on Order#items")
  end

  # CYRA-343: nessuna voce a schermo mostra più il gergo grezzo del codice.
  it "la colonna Tipo mostra la categoria tradotta, non il valore grezzo col trattino basso" do
    create(:metric_group, project:, kind: :slow_query, title: "SELECT * FROM widgets")
    sign_in_as(admin_account)

    visit member_monitoring_metric_groups_path

    within "[data-test='metric-group-row']" do
      expect(page).to have_text(I18n.t("member.metrics.kind.slow_query"))
      expect(page).not_to have_text("slow_query")
    end
  end

  it "nell'elenco la signature di un verdetto non mostra il prefisso tecnico del subtype (CYRA-343)" do
    group = create(:metric_group, :performance_issue, project:, fingerprint: "pi-343",
                   title: "n_plus_one SELECT * FROM orders WHERE id = <n> app/models/order.rb:42")
    sign_in_as(admin_account)

    visit member_monitoring_metric_groups_path

    within "[data-test='metric-group-link-#{group.id}']" do
      expect(page).to have_text("SELECT * FROM orders WHERE id = <n> app/models/order.rb:42")
      expect(page).not_to have_text("n_plus_one")
    end
    # Il tipo di problema resta leggibile come badge a parte.
    expect(page).to have_text(I18n.t("member.metrics.subtype.n_plus_one"))
  end

  it "il percorso in cima al dettaglio mostra sempre il nome leggibile della categoria (CYRA-343)" do
    group = create(:metric_group, project:, kind: :slow_query, title: "SELECT * FROM widgets")
    sign_in_as(admin_account)

    visit member_monitoring_metric_group_path(group)

    expect(all("[data-test='breadcrumb-crumb']").last).to have_text(I18n.t("member.metrics.kind.slow_query"))
  end

  it "nel dettaglio di un verdetto la signature e il percorso non mostrano il prefisso grezzo (CYRA-343)" do
    group = create(:metric_group, :performance_issue, project:, fingerprint: "pi-show-343",
                   title: "n_plus_one SELECT * FROM orders WHERE id = <n> app/models/order.rb:42")
    create(:metric_sample, group:, project:, kind: :performance_issue, subtype: "n_plus_one",
           occurred_at: 1.minute.ago, duration_ms: 320, payload: { "sql" => "SELECT 1" })
    sign_in_as(admin_account)

    visit member_monitoring_metric_group_path(group)

    within "[data-test='query-panel']" do
      expect(page).to have_text("SELECT * FROM orders WHERE id = <n> app/models/order.rb:42")
      expect(page).not_to have_text("n_plus_one")
    end
    expect(all("[data-test='breadcrumb-crumb']").last).to have_text(I18n.t("member.metrics.subtype.n_plus_one"))
    # Anche il titolo della scheda del browser è ripulito dal prefisso tecnico.
    expect(page).to have_title("SELECT * FROM orders WHERE id =")
    expect(page).to have_title("app/models/order.rb:42")
    expect(page.title).not_to include("n_plus_one")
  end

  it "i filtri Categoria e Tipo di problema portano una spiegazione per ogni voce (CYRA-343)" do
    create(:metric_group, project:, title: "SELECT 1") # una riga: la toolbar coi filtri viene resa
    sign_in_as(admin_account)

    visit member_monitoring_metric_groups_path

    kind_option = find("select[data-test='filter-kind'] option[value='slow_query']", visible: :all)
    expect(kind_option["data-description"]).to be_present
    subtype_option = find("select[data-test='filter-subtype'] option[value='n_plus_one']", visible: :all)
    expect(subtype_option["data-description"]).to be_present
  end

  # CYRA-341 — scenario 1: si apre la scheda di un rallentamento per sapere se sta peggiorando.
  describe "andamento della durata (CYRA-341)" do
    it "la scheda mostra il grafico della durata nel tempo, non solo quello delle occorrenze" do
      group = create(:metric_group, project:, title: "SELECT * FROM orders")
      create(:metric_sample, group:, project:, occurred_at: 1.hour.ago, duration_ms: 900)
      sign_in_as(admin_account)

      visit member_monitoring_metric_group_path(group)

      expect_test "duration-trend-chart"
      expect_test "duration-trend-buckets"
    end

    it "confronta il periodo con quello precedente della stessa lunghezza" do
      group = create(:metric_group, project:, title: "SELECT * FROM orders")
      create(:metric_sample, group:, project:, occurred_at: 2.hours.ago, duration_ms: 800)
      create(:metric_sample, group:, project:, occurred_at: 30.hours.ago, duration_ms: 400)
      sign_in_as(admin_account)

      visit member_monitoring_metric_group_path(group)

      expect(find("[data-test='stat-window-avg']")).to have_text("800ms")
      expect(find("[data-test='stat-window-avg-trend']")).to have_text("100%")
      within "[data-test='duration-trend-chart']" do
        expect(page).to have_text(I18n.t("member.metrics.compare.24h"))
      end
    end

    it "senza dati nel periodo precedente lo dice invece di inventare una variazione" do
      group = create(:metric_group, project:, title: "SELECT * FROM orders")
      create(:metric_sample, group:, project:, occurred_at: 2.hours.ago, duration_ms: 800)
      sign_in_as(admin_account)

      visit member_monitoring_metric_group_path(group)

      expect(page).to have_no_css("[data-test='stat-window-avg-trend']")
      within "[data-test='duration-trend-chart']" do
        expect(page).to have_text(I18n.t("member.metrics.compare_missing"))
      end
    end

    # Il grafico vede solo i casi ancora conservati: va detto in pagina, non lasciato intuire.
    it "dichiara che l'andamento usa i casi ancora conservati" do
      group = create(:metric_group, project:, title: "SELECT * FROM orders")
      create(:metric_sample, group:, project:, occurred_at: 1.hour.ago, duration_ms: 900)
      sign_in_as(admin_account)

      visit member_monitoring_metric_group_path(group)

      expect_test "duration-trend-retention-note"
    end
  end

  # CYRA-341 — scenario 2: nell'elenco una durata è rossa e la soglia non è scritta da nessuna parte.
  describe "soglie di colore (CYRA-341)" do
    it "nell'elenco il valore colorato dichiara la soglia che ha deciso il colore" do
      group = create(:metric_group, project:, title: "SELECT * FROM orders",
                                    samples_count: 10, duration_total_ms: 8_000.0)
      sign_in_as(admin_account)

      visit member_monitoring_metric_groups_path

      cella = find("[data-test='metric-group-avg-#{group.id}']")
      expect(cella[:title]).to include("150ms").and include("500ms")
      expect(cella[:class]).to include("text-red-600")
    end

    it "il dettaglio spiega la soglia e da dove si cambia" do
      group = create(:metric_group, project:, title: "SELECT * FROM orders",
                                    samples_count: 10, duration_total_ms: 8_000.0)
      sign_in_as(admin_account)

      visit member_monitoring_metric_group_path(group)

      expect_test "help-metric-threshold"
      # Il pannello del tooltip vive nel DOM e si apre al passaggio del mouse.
      pannello = find("[data-test='help-metric-threshold'] [role='tooltip']", visible: :all)
      expect(pannello.text(:all)).to include("150ms").and include("500ms")
      expect(pannello).to have_link(href: member_project_settings_path(project), visible: :all)
    end

    it "cambiare la soglia del progetto cambia subito il colore del valore" do
      group = create(:metric_group, project:, title: "SELECT * FROM orders",
                                    samples_count: 10, duration_total_ms: 8_000.0)
      project.update!(performance_slow_ms: 2_000)
      sign_in_as(admin_account)

      visit member_monitoring_metric_groups_path

      cella = find("[data-test='metric-group-avg-#{group.id}']")
      expect(cella[:class]).to include("text-amber-600")
      expect(cella[:title]).to include("2s")
    end
  end

  it "il dettaglio di un verdetto performance_issue mostra i log correlati della stessa richiesta (trace_id)" do
    group = create(:metric_group, :performance_issue, project:, title: "N+1 SELECT users")
    create(:metric_sample, group:, project:, kind: :performance_issue, subtype: "n_plus_one",
                           trace_id: "req-42", occurred_at: 1.minute.ago, duration_ms: 320,
                           payload: { "query_count" => 47, "source" => "app/models/user.rb:10", "sql" => "SELECT * FROM users WHERE id = ?" })
    create(:log_entry, project:, trace_id: "req-42", message: "ProcessedOrderLog")
    sign_in_as(admin_account)

    visit member_monitoring_metric_group_path(group)

    expect_test "member-metric-group"
    expect_test "trace-correlation"
    expect(page).to have_text("ProcessedOrderLog")
    expect(page).to have_text("app/models/user.rb:10")
  end
end
