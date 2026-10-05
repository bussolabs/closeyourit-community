# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member error monitoring", type: :system do
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

  it "un admin apre la lista e naviga al dettaglio di una issue" do
    group = create(:error_group, project:, title: "RuntimeError: boom", culprit: "App::Checkout#summary")
    create(:error_event, group:, project:, occurred_at: 1.minute.ago,
           stacktrace: { "frames" => [ { "filename" => "app/services/checkout.rb", "function" => "summary", "in_app" => true, "lineno" => 48 } ] })
    sign_in_as(admin_account)

    visit member_monitoring_error_groups_path
    expect_test "error-groups-table"
    expect(page).to have_text("RuntimeError: boom")
    # colonna Progetto dedicata: nome + key
    expect(page).to have_text("Storefront")
    expect(page).to have_text("STR")
    # errore non promosso → colonna Ticket senza link
    expect(page).not_to have_css("[data-test='error-group-ticket-#{group.id}']")

    find("[data-test='error-group-link-#{group.id}']").click

    expect_test "member-error-group"
    expect(page).to have_text("App::Checkout#summary")
    expect_test "stacktrace"
    expect(page).to have_text("app/services/checkout.rb")
  end

  it "mostra il link al ticket in colonna per un errore promosso, — per gli altri" do
    ticket = create(:ticket, organization: org, project:)
    promoted = create(:error_group, project:, ticket:, title: "NoMethodError: boom")
    plain = create(:error_group, project:, title: "ArgumentError: nope")
    sign_in_as(admin_account)

    visit member_monitoring_error_groups_path

    link = find("[data-test='error-group-ticket-#{promoted.id}']")
    expect(link[:href]).to end_with(member_ticket_path(ticket))
    expect(link).to have_text(ticket.code)
    expect(page).not_to have_css("[data-test='error-group-ticket-#{plain.id}']")
  end

  it "mostra i log collegati manualmente e il link porta alla pagina del log" do
    group = create(:error_group, project:, title: "RuntimeError: boom")
    entry = create(:log_entry, project:, message: "checkout failed")
    create(:log_link, log_entry: entry, linkable: group)
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)

    within_test("linked-log-entries") { expect(page).to have_text("checkout failed") }
    find("[data-test='linked-log-entry-#{entry.id}']").click
    expect_test "member-log-entry"
  end

  it "senza log collegati mostra lo stato vuoto del pannello" do
    group = create(:error_group, project:, title: "RuntimeError: boom")
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)

    # CYRA-986: with nothing linked the panel starts as one closed row.
    find("[data-test='linked-log-entries'] summary").click
    expect_test "linked-log-entries-empty"
  end

  # CYRA-192: «Risolvi» non chiude più al buio — apre i due campi in cui si scrive perché l'errore
  # c'era e cosa l'ha chiuso, e la spiegazione si rilegge sulla pagina.
  it "un admin risolve un errore dal dettaglio scrivendo causa e rimedio" do
    group = create(:error_group, project:, status: :unresolved)
    sign_in_as(admin_account)
    visit member_monitoring_error_group_path(group)

    click_on_test "triage-resolve"
    fill_test "resolve-cause", with: "Solid Cable su SQLite"
    fill_test "resolve-fix", with: "Guard anti-ricorsione nell'SDK"
    click_on_test "resolve-confirm"

    expect_test "flash-notice"
    expect(group.reload).to be_status_resolved
    expect(group.resolution_cause).to eq("Solid Cable su SQLite")
    expect(group.resolution_fix).to eq("Guard anti-ricorsione nell'SDK")

    visit member_monitoring_error_group_path(group)
    within_test("error-resolution") { expect(page).to have_text("Solid Cable su SQLite") }
  end

  # I due campi restano facoltativi: chi ha fretta conferma e basta, senza scrivere niente.
  it "un admin può risolvere senza scrivere la spiegazione" do
    group = create(:error_group, project:, status: :unresolved)
    sign_in_as(admin_account)
    visit member_monitoring_error_group_path(group)

    click_on_test "triage-resolve"
    click_on_test "resolve-confirm"

    expect_test "flash-notice"
    expect(group.reload).to be_status_resolved
  end

  # CYRA-192: la fusione parte dall'elenco (si vedono i doppioni scorrendo) e passa da una conferma
  # che elenca cosa sparisce — non da un «sei sicuro?» sopra una lista che non si vede più.
  it "un admin fonde due errori dall'elenco, passando dalla conferma" do
    primary = create(:error_group, project:, title: "RuntimeError: boom", events_count: 10)
    source = create(:error_group, project:, title: "RuntimeError: boom",
                                  culprit: "App::Other#call", events_count: 5)
    sign_in_as(admin_account)
    visit member_monitoring_error_groups_path

    check("ids[]", option: primary.id, allow_label_click: true)
    check("ids[]", option: source.id, allow_label_click: true)
    # La barra delle azioni resta [hidden] finché Stimulus non la mostra al primo checkbox, e qui
    # non gira JS: si preme il bottone dov'è, che è esattamente ciò che il browser farebbe dopo.
    find("[data-test='errors-bulk-merge']", visible: :all).click

    # La conferma dice cosa si sta fondendo prima di chiedere il via libera.
    expect_test "error-merge-preview"
    expect(page).to have_text("App::Other#call")
    choose(option: primary.id, allow_label_click: true)
    click_on_test "merge-confirm"
    conferma_azione_pericolosa

    expect_test "flash-notice"
    expect(primary.reload.events_count).to eq(15)
    expect(Errors::Group.exists?(source.id)).to be(false)
  end

  it "un admin elimina un errore dopo la conferma" do
    group = create(:error_group, project:, status: :resolved)
    sign_in_as(admin_account)
    visit member_monitoring_error_group_path(group)

    click_on_test "error-delete"
    click_on_test "delete-confirm"
    conferma_azione_pericolosa

    expect_test "flash-notice"
    expect(Errors::Group.exists?(group.id)).to be(false)
  end

  it "un admin promuove un errore a ticket" do
    group = create(:error_group, project:, title: "RuntimeError: boom", culprit: "App::X#y")
    sign_in_as(admin_account)
    visit member_monitoring_error_group_path(group)

    # CYRA-382: il pulsante apre l'anteprima di ciò che verrà creato; si conferma da lì.
    click_on_test "promote-ticket"
    click_on_test "promote-preview-confirm"

    expect_test "flash-notice"
    expect(group.reload).to be_promoted
    expect(project.tickets.count).to eq(1)
  end

  it "un member assegnato vede gli errori in sola lettura (niente azioni di triage)" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    group = create(:error_group, project:, status: :unresolved)
    sign_in_as(member)

    visit member_monitoring_error_group_path(group)

    expect_test "member-error-group"
    expect(page).not_to have_css("[data-test='triage-actions']")
  end

  it "un customer vede il lede in linguaggio semplice; gli altri ruoli no" do
    customer = create(:account)
    create(:membership, account: customer, organization: org, role: :customer)
    create(:project_membership, account: customer, project: project)
    group = create(:error_group, project:, status: :unresolved)

    sign_in_as(customer)
    visit member_monitoring_error_group_path(group)
    expect_test "member-error-group"
    expect_test "customer-lede"

    sign_in_as(admin_account)
    visit member_monitoring_error_group_path(group)
    expect_test "member-error-group"
    expect(page).not_to have_css("[data-test='customer-lede']")
  end

  it "cabla i tasti di triage e apre l'help condiviso; il bottone è visibile a tutti i ruoli" do
    group = create(:error_group, project:, status: :unresolved)

    sign_in_as(admin_account)
    visit member_monitoring_error_group_path(group)
    # tasti di triage r/i/p montati sulla pagina (progressive enhancement)
    expect(page).to have_css("[data-controller~='keyboard-shortcuts']")
    # il bottone tastiera apre l'help GLOBALE del layout (CYRA-28), non più un cheatsheet locale
    expect(find("[data-test='shortcuts-open']")["data-action"]).to include("keyboard#openHelp")
    expect(page).to have_css("[data-test='keyboard-help-dialog']", visible: :all)
    # la pagina dichiara i suoi binding nel registry dell'help condiviso
    expect(find("[data-keyboard-doc]")["data-keyboard-doc"]).to include("r", "i", "p")
    expect_test "triage-actions"

    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    sign_in_as(member)
    visit member_monitoring_error_group_path(group)
    expect_test "shortcuts-open"
    expect(page).not_to have_css("[data-test='triage-actions']")
  end

  # CYRA-382 — il Promote resta irreversibile, ma la protezione non è più un "sei sicuro?" secco:
  # è l'anteprima di ciò che verrà creato (progetto, tipo, titolo, allegati), che dice COSA si sta
  # confermando invece di chiedere solo SE.
  it "protegge il Promote irreversibile con l'anteprima di ciò che verrà creato" do
    group = create(:error_group, project:, status: :unresolved, title: "RuntimeError: boom")
    sign_in_as(admin_account)
    visit member_monitoring_error_group_path(group)

    expect(page).to have_css("[data-test='promote-ticket']:not([href])", visible: :all)
    expect(page).to have_css("[data-test='promote-preview-dialog']", visible: :all)
    expect(page).to have_css("[data-test='promote-preview-title']", text: "RuntimeError: boom", visible: :all)
  end

  it "mostra l'istogramma occorrenze e il selettore di range" do
    group = create(:error_group, project:)
    create(:error_event, group:, project:, occurred_at: 1.minute.ago)
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)

    expect_test "error-histogram"
    expect_test "error-buckets"
    expect_test "range-30m"
    expect_test "range-7d"
    expect_test "range-30d"

    %w[30m 24h 7d 30d].each do |range|
      expect(find("[data-test='range-#{range}']")[:class]).to include("h-11", "md:h-[34px]")
    end
  end

  # CYRA-46: lo scenario del ticket. Uno spike 3 giorni fa, le occorrenze recenti sono tutte di oggi:
  # cliccare la barra del picco filtra la tabella a quel blocco e l'occorrenza vecchia diventa apribile.
  it "drill-down: cliccare la barra dell'istogramma filtra le occorrenze al suo blocco temporale" do
    freeze_time do
      group = create(:error_group, project:)
      spike = create(:error_event, group:, project:, occurred_at: 3.days.ago + 1.hour)
      (Monitoring::Constants::OCCURRENCES_PER_PAGE + 3).times do |i|
        create(:error_event, group:, project:, occurred_at: (i + 1).minutes.ago)
      end
      sign_in_as(admin_account)

      # range 7d: lo spike di 3 giorni fa e il gruppo di oggi cadono in blocchi distinti
      visit member_monitoring_error_group_path(group, range: "7d")
      # la tabella parte dalle occorrenze recenti (CYRA-400: cinque mostrate, il resto dietro il comando)
      expect(page).to have_css("[data-test='occurrence-row']", count: Monitoring::Constants::OCCURRENCES_COLLAPSED)
      expect(page).to have_css("a[data-test='bucket-link']", minimum: 2)

      # il primo blocco cliccabile nel DOM è il più vecchio (lo spike)
      first("a[data-test='bucket-link']").click

      expect_test "bucket-filter"
      expect(page).to have_css("[data-test='occurrence-row']", count: 1)
      expect(page).to have_text(spike.event_id.truncate(12))

      # rimuovere il filtro torna a mostrare le occorrenze recenti
      click_on_test "bucket-filter-clear"
      expect(page).to have_css("[data-test='occurrence-row']", count: Monitoring::Constants::OCCURRENCES_COLLAPSED)
      expect(page).not_to have_css("[data-test='bucket-filter']")
    end
  end

  it "drill-down: un pannello per occorrenza, il più recente selezionato (non hidden)" do
    group = create(:error_group, project:)
    recent = create(:error_event, group:, project:, occurred_at: 1.minute.ago,
                    payload: { "request" => { "method" => "GET", "url" => "https://x/a" } })
    older = create(:error_event, group:, project:, occurred_at: 9.minutes.ago,
                   payload: { "request" => { "method" => "POST", "url" => "https://x/b" } })
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)

    # CYRA-986: one panel per occurrence, all in the DOM; its tabs hold the related logs (CYRA-51)
    # and the session replay (CYRA-376). The count is exact on purpose: a part rendered outside the
    # occurrence's own panel would show the data of the wrong occurrence.
    panels = 1
    [ recent, older ].each do |event|
      expect(page).to have_css("[data-panel-id='#{event.id}'] [data-test='error-related-logs']", count: 1, visible: :all)
      expect(page).to have_css("[data-panel-id='#{event.id}'] [data-test='error-replay-none']", count: 1, visible: :all)
    end
    expect(page).to have_css("[data-panel-id='#{recent.id}']", count: panels, visible: :all)
    expect(page).to have_css("[data-panel-id='#{older.id}']", count: panels, visible: :all)
    # il più recente è il selezionato (server-side) → non hidden; il vecchio hidden
    expect(page).to have_css("[data-panel-id='#{recent.id}']:not(.hidden)", count: panels, visible: :all)
    expect(page).to have_css("[data-panel-id='#{older.id}'].hidden", count: panels, visible: :all)
  end

  # CYRA-51: i log correlati seguono l'occorrenza selezionata. Con rack_test (no JS) il toggle è
  # client-side, ma i pannelli sono resi server-side: i log di OGNI occorrenza sono già nel DOM, quello
  # dell'occorrenza non selezionata in un pannello hidden. Prima del fix il pannello mostrava solo i log
  # della richiesta più recente (@selected), correlando lo stacktrace di #N coi log di #1.
  it "rende i log della richiesta di ogni occorrenza, ciascuno legato all'evento via data-panel-id" do
    group = create(:error_group, project:)
    recent = create(:error_event, group:, project:, occurred_at: 1.minute.ago, trace_id: "trace-recent")
    older = create(:error_event, group:, project:, occurred_at: 9.minutes.ago, trace_id: "trace-older")
    create(:log_entry, project:, trace_id: "trace-recent", message: "log richiesta recente")
    create(:log_entry, project:, trace_id: "trace-older", message: "log richiesta vecchia")
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)

    # il pannello log del più recente (selezionato) è visibile e coi suoi log
    within("[data-panel-id='#{recent.id}'] [data-test='error-related-logs']") do
      expect(page).to have_text("log richiesta recente")
      expect(page).to have_text("trace-recent")
    end
    # il pannello log del vecchio è nel DOM (hidden, togglato al click) coi log della SUA richiesta
    # (rack_test ignora il display CSS della classe .hidden → il testo resta raggiungibile)
    within("[data-panel-id='#{older.id}'] [data-test='error-related-logs']") do
      expect(page).to have_text("log richiesta vecchia")
      expect(page).to have_text("trace-older")
    end
    expect(page).to have_css("[data-panel-id='#{older.id}'].hidden [data-test='error-related-logs']", visible: :all)
  end

  it "filtra le occorrenze per environment (param diretto)" do
    group = create(:error_group, project:)
    create(:error_event, group:, project:, environment: "production", occurred_at: 1.minute.ago)
    create(:error_event, group:, project:, environment: "staging", occurred_at: 2.minutes.ago)
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)
    expect(page).to have_css("[data-test='occurrence-row']", count: 2)

    visit member_monitoring_error_group_path(group, environment: [ "production" ])
    expect(page).to have_css("[data-test='occurrence-row']", count: 1)
  end

  it "pagina le occorrenze (max per pagina) e naviga con il pager" do
    group = create(:error_group, project:)
    per = Monitoring::Constants::OCCURRENCES_PER_PAGE
    (per + 3).times { |i| create(:error_event, group:, project:, occurred_at: (i + 1).minutes.ago) }
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)
    # CYRA-400: la pagina ne contiene `per`, ne mostra cinque; il comando apre le restanti
    expect(page).to have_css("[data-test='occurrence-row']", count: Monitoring::Constants::OCCURRENCES_COLLAPSED)
    expect_test "occurrences-pagination"

    click_on_test "occurrences-show-all"
    expect(page).to have_css("[data-test='occurrence-row']", count: per)

    click_on_test "pagination-next"
    expect(page).to have_css("[data-test='occurrence-row']", count: 3)
  end

  it "il pager delle occorrenze preserva il filtro environment tra le pagine" do
    group = create(:error_group, project:)
    per = Monitoring::Constants::OCCURRENCES_PER_PAGE
    (per + 2).times { |i| create(:error_event, group:, project:, environment: "production", occurred_at: (i + 1).minutes.ago) }
    create(:error_event, group:, project:, environment: "staging", occurred_at: 1.second.ago)
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group, environment: [ "production" ])
    expect(page).to have_css("[data-test='occurrence-row']", count: Monitoring::Constants::OCCURRENCES_COLLAPSED)
    expect(find("[data-test='pagination-next']")[:href]).to include("environment")

    click_on_test "pagination-next"
    # pagina 2: solo le 2 production restanti, la staging resta esclusa dal filtro
    expect(page).to have_css("[data-test='occurrence-row']", count: 2)
  end

  it "non mostra PII (email) nel pannello user, solo l'id" do
    group = create(:error_group, project:)
    create(:error_event, group:, project:, occurred_at: 1.minute.ago,
           payload: { "user" => { "id" => "9", "email" => "secret@example.com" } })
    sign_in_as(admin_account)

    visit member_monitoring_error_group_path(group)

    expect_test "error-user"
    expect(page).to have_text("9")
    expect(page).not_to have_text("secret@example.com")
  end
end
