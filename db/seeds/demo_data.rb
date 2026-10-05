# frozen_string_literal: true

# CYRA-929 — plenty of example data on the Demo organization, so every member page can be looked at
# full, lists past one page included. Development only, loaded by db/seeds.rb after the demo projects.
# Every example record has its own key (fingerprint, title, event id) and is created only when that
# key is missing: re-seeding adds nothing twice and sits beside data already there. The "empty"
# organization stays bare, for the empty states.

org = Organizations::Organization.find_by!(slug: "demo")
god = Accounts::Account.find_by!(email: "god@closeyour.it")
admin = Accounts::Account.find_by(email: "admin@demo.test")
member = Accounts::Account.find_by(email: "member@demo.test")
production = org.environments.find_by!(code: "production")
now = Time.current
web = org.platforms.find_by(code: "web")

# --- More projects: the project lists and the Observability table run past one page (12 rows). ---
extra_projects = [
  %w[MOB Mobile\ App sky], %w[ADM Admin\ Panel slate], %w[SRCH Search\ Service teal], %w[NOTI Notifications rose],
  %w[BILL Billing lime], %w[AUTH Auth\ Gateway orange], %w[DATA Data\ Pipeline cyan], %w[MKT Marketing\ Site pink],
  %w[INV Inventory emerald], %w[SHIP Shipping amber]
]
extra_projects.each do |key, name, color|
  Projects::Project.find_or_create_by!(organization: org, key:) do |project|
    project.name = name
    project.color = color
    project.created_by = god
    project.platforms = [ web ].compact
  end
end
projects = Projects::Project.where(organization: org).order(:key).index_by(&:key)
busy = projects.values_at("STR", "API", "DASH").compact

# --- Tickets: three pages of them, in every status and priority. ---
begin
  statuses = org.ticket_statuses.to_a
  priorities = org.ticket_priorities.to_a
  subjects = [
    "Il filtro per data ignora il fuso orario", "La ricerca non trova i nomi con l'apostrofo", "Esportazione CSV senza intestazioni",
    "Il link di reset password scade subito", "Notifiche email duplicate al cambio stato", "Pagina prodotti lenta oltre i 500 articoli",
    "Il carrello si svuota dopo il login", "Errore 500 caricando un'immagine HEIC", "Paginazione salta l'ultima pagina",
    "Totale ordine arrotondato male", "Traduzione mancante nel riepilogo", "Il menu mobile non si chiude",
    "Timeout sul webhook del corriere", "Avatar non aggiornato dopo il cambio", "Lo scroll infinito ricarica gli stessi elementi",
    "Badge non lette sempre a zero", "Il grafico mensile parte da martedì", "Doppio clic crea due ordini",
    "Il token API non si revoca", "Campo telefono accetta lettere", "Sessione persa cambiando scheda",
    "Ordinamento per prezzo invertito", "Il PDF della fattura taglia il footer", "Filtri non ricordati tra le pagine",
    "Immagini non compresse nel catalogo", "La dark mode non segue il sistema", "Lento il primo caricamento su 3G",
    "Coupon applicabile due volte", "Errore di validazione poco chiaro", "Il calendario mostra il mese sbagliato"
  ]
  subjects.each_with_index do |title, index|
    next if Ticketing::Ticket.exists?(project: projects.values, title:)

    ticket = Ticketing::Ticket.new(project: projects.values[index % projects.size], title:)
    ticket.reporter = god
    ticket.status = statuses[index % statuses.size]
    ticket.priority = priorities[index % priorities.size]
    ticket.assignee = [ admin, member, nil ][index % 3]
    ticket.scenarios.build(position: 0, step_given: "un utente sulla pagina interessata", step_when: "ripete l'azione",
                           step_then: "il problema si presenta", step_expected: "tutto funziona come previsto")
    ticket.save!
  end
end

# --- Errors: groups with a 48-hour history, Payments API getting worse since yesterday. ---
begin
  errors = {
    "API" => [ [ "Stripe::CardError: Your card was declined", "PaymentsController#create", 14 ],
               [ "ActiveRecord::Deadlocked: deadlock detected", "Orders::Finalize#call", 6 ],
               [ "Net::ReadTimeout: Net::ReadTimeout", "Webhooks::Deliver#perform", 9 ] ],
    "STR" => [ [ "TypeError: Cannot read properties of undefined (reading 'price')", "cart.js:142", 7 ],
               [ "ChunkLoadError: Loading chunk 312 failed", "checkout.js:1", 3 ] ],
    "DASH" => [ [ "NoMethodError: undefined method `sum' for nil", "Reports::Monthly#totals", 4 ] ],
    "AUTH" => [ [ "JWT::ExpiredSignature: Signature has expired", "Sessions::Verify#call", 5 ] ],
    "BILL" => [ [ "ZeroDivisionError: divided by 0", "Invoices::Tax#rate", 2 ] ]
  }
  errors.each do |key, rows|
    rows.each_with_index do |(title, culprit, recent), index|
      project = projects.fetch(key)
      next if Errors::Group.exists?(project:, fingerprint: "seed-#{key}-#{index}")

      older = key == "API" ? 2 : recent # API: more today than yesterday, the cell turns red
      times = Array.new(recent) { |n| now - (n * 23 / recent.to_f).hours - 10.minutes } +
              Array.new(older) { |n| now - 25.hours - (n * 22 / older.to_f).hours }
      group = Errors::Group.create!(project:, fingerprint: "seed-#{key}-#{index}", title:, culprit:, level: :error,
                                    status: :unresolved, events_count: times.size, users_count: index + 1,
                                    first_seen_at: times.min, last_seen_at: times.max)
      times.each_with_index do |at, n|
        Errors::Event.create!(group:, project:, event_id: "seed-#{key}-#{index}-#{n}", occurred_at: at, created_at: at,
                              level: :error, environment: "production", payload: { "message" => title })
      end
    end
  end
  Errors::Group.find_or_create_by!(project: projects.fetch("STR"), fingerprint: "seed-STR-resolved") do |group|
    group.assign_attributes(title: "RangeError: Invalid time value", culprit: "date.js:18", level: :error, status: :resolved,
                            events_count: 1, users_count: 0, first_seen_at: 5.days.ago, last_seen_at: 5.days.ago)
  end
end

# --- Logs: two days of lines on the three busy projects; the others never wrote any. ---
if Logs::Entry.where(project: busy).where("event_id LIKE ?", "seed-%").none?
  messages = {
    info: [ "Order %d confirmed", "User %d signed in", "Cache warmed in %d ms", "Job %d enqueued" ],
    warning: [ "Slow query took %d ms", "Retrying webhook attempt %d" ],
    error: [ "Payment provider answered 502 for order %d", "Could not send email %d" ]
  }
  busy.each do |project|
    60.times do |n|
      level = n % 10 == 0 ? :error : (n % 4 == 0 ? :warning : :info)
      at = now - (n * 48 / 60.0).hours - rand(0..30).minutes
      Logs::Entry.create!(project:, event_id: "seed-#{project.key}-#{n}", level:,
                          message: format(messages.fetch(level).sample, rand(100..9999)), data: { "request_id" => SecureRandom.hex(4) },
                          logger_name: "application", environment: "production", occurred_at: at, created_at: at)
    end
  end
end

# --- Performance: slow queries and methods on Payments API and Storefront. ---
if Metrics::Group.where(project: projects.values).where("fingerprint LIKE ?", "seed-%").none?
  [ [ "API", :slow_query, "SELECT * FROM orders WHERE customer_id = ? ORDER BY created_at DESC", 840 ],
    [ "API", :slow_method, "Orders::Finalize#call", 1_250 ],
    [ "STR", :slow_query, "SELECT * FROM products WHERE category_id = ?", 410 ],
    [ "STR", :slow_method, "Catalog::Search#results", 620 ] ].each_with_index do |(key, kind, title, ms), index|
    Metrics::Group.create!(project: projects.fetch(key), fingerprint: "seed-metric-#{index}", title:, kind:, samples_count: 40,
                           duration_total_ms: ms * 40.0, duration_min_ms: ms / 3.0, duration_max_ms: ms * 2.5,
                           first_seen_at: 6.days.ago, last_seen_at: 1.hour.ago)
  end
end

# --- Vulnerabilities: a Gemfile.lock with four open findings on Payments API. ---
api = projects.fetch("API")
if Vulnerabilities::Manifest.where(project: api, path: "Gemfile.lock").none?
  manifest = Vulnerabilities::Manifest.create!(project: api, path: "Gemfile.lock", ecosystem: Vulnerabilities::Ecosystem::RUBYGEMS,
                                               blob_sha: SecureRandom.hex(20), content_digest: SecureRandom.hex(32), scanned_at: now)
  [ [ "rack", "2.2.6", "2.2.8", :high, "Possible denial of service in multipart parsing" ],
    [ "nokogiri", "1.14.2", "1.14.3", :critical, "Use-after-free in libxml2" ],
    [ "actionpack", "7.0.4", "7.0.4.3", :moderate, "Possible XSS in Action Controller" ],
    [ "jwt", "2.5.0", nil, :low, "Timing difference in signature verification" ] ].each_with_index do |(name, version, fixed, severity, summary), index|
    package = Vulnerabilities::Package.create!(manifest:, name:, version:, ecosystem: manifest.ecosystem, direct: index.even?)
    advisory = Vulnerabilities::Advisory.find_or_create_by!(osv_id: "GHSA-seed-#{name}") do |a|
      a.aliases = [ "CVE-2026-#{1000 + index}" ]
      a.summary = summary
      a.details = summary
      a.severity = severity
      a.published_at = 20.days.ago
      a.modified_at = 2.days.ago
      a.refreshed_at = now
    end
    Vulnerabilities::Finding.create!(package:, advisory:, project: api, fixed_version: fixed, status: :open,
                                     first_seen_at: 3.days.ago, last_seen_at: now)
  end
end

# --- Session replay: turned on for Storefront, with recordings. ---
storefront = projects.fetch("STR")
storefront.update!(session_replay_enabled: true) unless storefront.session_replay_enabled?
if Replays::Session.where(project: storefront).none?
  14.times do |n|
    started = now - (n * 3).hours
    Replays::Session.create!(project: storefront, replay_session_id: SecureRandom.uuid, started_at: started,
                             ended_at: started + rand(1..9).minutes, duration_ms: rand(60_000..540_000))
  end
end

# --- Uptime: production checks, one of them down. Staging has uptime off by default: left alone. ---
begin
  [ [ "STR", production, "https://shop.example.com/up", :up ], [ "API", production, "https://api.example.com/health", :up ],
    [ "DASH", production, "https://dash.example.com/up", :down ], [ "AUTH", production, "https://auth.example.com/health", :up ] ]
    .each do |key, environment, url, state|
    next if Uptime::Monitor.exists?(project: projects.fetch(key), environment:)

    # A monitor watches an environment its project declares: declare it on a fresh database.
    projects.fetch(key).environments << environment unless projects.fetch(key).environment_ids.include?(environment.id)
    monitor = Uptime::Monitor.create!(project: projects.fetch(key), environment:, name: "#{projects.fetch(key).name} · #{environment.code}",
                                      url:, http_method: "GET", interval_seconds: 60, expected_status: 200, timeout_seconds: 5,
                                      active: true, current_status: state)
    24.times do |n|
      up = state == :up || n > 2
      Uptime::Check.create!(monitor:, up:, status_code: (up ? 200 : nil), response_time_ms: (up ? rand(80..400) : nil),
                            error: (up ? nil : "timeout"), checked_at: now - n.hours)
    end
  end
end

# --- Ideas, knowledge, todos, workload and notifications. ---
begin
  [ "Pagamento in tre rate", "Wishlist condivisibile", "Ricerca vocale nel catalogo", "Report settimanale via email",
    "Login con passkey", "Modalità offline per l'app", "Suggerimenti di prodotti simili", "Dashboard per i corrieri",
    "Esportazione in Excel", "Avvisi di riassortimento", "Programma fedeltà", "Chat con l'assistenza",
    "Tema ad alto contrasto", "Integrazione con Slack" ].each_with_index do |title, index|
    Ideas::Idea.create!(project: projects.values[index % projects.size], author: [ god, admin, member ].compact[index % 3],
                        title:, problem: "Oggi chi lo chiede deve arrangiarsi a mano.", solution: "Una funzione dedicata.",
                        stakeholders: [], status: index % 5 == 4 ? :archived : :open) unless Ideas::Idea.exists?(project: projects.values, title:)
  end
end

begin
  [ [ "Come si rilascia in produzione", :guide ], [ "Perché usiamo PostgreSQL per le code", :decision ],
    [ "Convenzioni dei nomi dei branch", :note ], [ "Gestione dei segreti", :guide ], [ "Scelta del provider di pagamento", :decision ],
    [ "Checklist per una nuova API", :note ], [ "Runbook: il sito è giù", :guide ], [ "Politica di conservazione dei log", :decision ],
    [ "Glossario del dominio ordini", :note ], [ "Come scrivere un buon ticket", :guide ], [ "Perché niente microservizi", :decision ],
    [ "Monitoraggio dei webhook", :note ], [ "Onboarding sviluppatori", :guide ], [ "Struttura dei report mensili", :note ] ]
    .each_with_index do |(title, kind), index|
    next if Knowledge::Page.exists?(organization: org, title:)

    page = Knowledge::Page.new(organization: org, created_by: god, title:, kind:,
                               body: "#{title}: cosa sapere, in breve, e dove trovare il resto.")
    page.projects << projects.values[index % projects.size]
    page.save!
  end
end

if Todos::List.where(organization: org, account: god, name: "Questa settimana").none?
  list = Todos::List.create!(organization: org, account: god, name: "Questa settimana", color: "indigo", position: 0)
  [ "Rivedere i ticket in review", "Rispondere alle domande aperte", "Aggiornare la guida di rilascio",
    "Controllare gli errori di Payments API", "Pianificare la retro", "Chiudere le idee archiviate",
    "Verificare i backup", "Ruotare il token del corriere", "Preparare la demo di venerdì",
    "Leggere il report SEO", "Sistemare i monitor di staging", "Rivedere i permessi dei clienti",
    "Aggiornare le dipendenze", "Scrivere le note di rilascio" ].each_with_index do |title, index|
    Todos::Item.create!(list:, title:, position: index, done: index % 4 == 3)
  end
end

team = Teams::Team.find_by(organization: org, name: "Administrators")
if team && Workload::Action.where(team:, title: "Migrare i job sul nuovo worker").none?
  [ "Migrare i job sul nuovo worker", "Ridurre i tempi della build", "Aggiornare Ruby", "Pulire i bucket vecchi",
    "Rivedere gli alert notturni", "Documentare il runbook pagamenti", "Testare il restore del database",
    "Aggiornare i certificati", "Sistemare i log rumorosi", "Preparare il piano di capacità",
    "Rivedere i costi cloud", "Automatizzare il rilascio mobile", "Ridurre le query lente" ].each_with_index do |title, index|
    Workload::Action.create!(team:, created_by: god, title:, status: %i[planned in_progress done][index % 3])
  end
end

if Alerting::Notification.where(organization: org, account: god).where("dedup_key LIKE ?", "seed-%").none?
  Errors::Group.where(project: projects.values).where("fingerprint LIKE ?", "seed-%").status_unresolved.limit(7).each_with_index do |group, index|
    2.times do |n|
      Alerting::Notification.create!(organization: org, account: god, project: group.project, subject: group, via: :in_app,
                                     event_type: n.zero? ? :error_new : :error_regression, title: "#{n.zero? ? 'New error' : 'Regression'} · #{group.title}",
                                     body: group.culprit, url: "/member/monitoring/error/#{group.id}", status: :sent,
                                     dedup_key: "seed-#{group.id}-#{n}", read_at: (index.even? ? nil : 1.hour.ago))
    end
  end
end

# --- Help desk: requests written by the visitors of three sites, past one page, a few discarded. ---
# Each request has its own summary as key. The addresses are made up, on a domain that cannot exist.
begin
  helpdesk_projects = projects.values_at("STR", "API", "MKT").compact
  helpdesk_projects.each { |project| project.update!(helpdesk_enabled: true) unless project.helpdesk_enabled? }
  devices = [ %w[Chrome macOS desktop], %w[Safari iOS mobile], %w[Firefox Windows desktop], %w[Chrome Android mobile] ]
  [ [ "Non riesco a pagare con la carta", "Al momento di pagare la pagina resta ferma e poi torna al carrello. Ho provato due carte.", "anna", "/carrello" ],
    [ "Il codice sconto non viene accettato", "Inserisco il codice ricevuto per email ma mi dice che non è valido.", "luca", "/carrello" ],
    [ "Ho ricevuto un prodotto sbagliato", "Ho ordinato la taglia M ed è arrivata la S. Come faccio il cambio?", "giulia", "/ordini" ],
    [ "Non mi arriva l'email di conferma", "Ho fatto l'ordine un'ora fa e non ho ricevuto niente, nemmeno nello spam.", "marco", "/ordini" ],
    [ "Vorrei cambiare l'indirizzo di consegna", "Ho sbagliato il numero civico. L'ordine non è ancora partito.", "sara", "/account/indirizzi" ],
    [ "La pagina del prodotto non si apre", "Clicco sulle scarpe blu e vedo una pagina bianca.", nil, "/prodotti/scarpe-blu" ],
    [ "Non riesco a entrare nel mio account", "Dice password sbagliata, ma l'ho appena cambiata.", "paolo", "/login" ],
    [ "Come faccio a chiedere la fattura?", "Mi serve la fattura intestata all'azienda per l'ordine di ieri.", "elena", "/ordini" ],
    [ "Il pacco risulta consegnato ma non c'è", "Il corriere segna consegnato alle 10, a casa non è arrivato niente.", "davide", "/ordini" ],
    [ "Le foto dei prodotti non si caricano", "Da telefono vedo solo dei riquadri grigi al posto delle immagini.", nil, "/prodotti" ],
    [ "Posso pagare alla consegna?", "Non trovo l'opzione del contrassegno fra i pagamenti.", "chiara", "/carrello" ],
    [ "La chiave delle API ha smesso di funzionare", "Da stamattina ogni chiamata risponde 401. Non abbiamo cambiato niente.", "dev", "/docs/autenticazione" ],
    [ "Vorrei disdire l'abbonamento", "Non trovo il pulsante per disdire nella pagina del mio piano.", "franco", "/account/piano" ],
    [ "Il modulo di contatto dà errore", "Premo Invia e compare «qualcosa è andato storto».", "marta", "/contatti" ],
    [ "Quando torna disponibile la giacca verde?", "È esaurita da due settimane. Potete avvisarmi?", "irene", "/prodotti/giacca-verde" ],
    [ "Ho pagato due volte lo stesso ordine", "Sul conto vedo due addebiti uguali per un ordine solo.", "simone", "/ordini" ],
    [ "Guadagna 500 euro al giorno da casa", "Clicca qui per scoprire il metodo che le banche non vogliono farti sapere.", "promo", "/contatti" ],
    [ "prova", "prova prova", nil, "/contatti" ],
    [ "Vendiamo visite al tuo sito", "Diecimila visitatori al mese a un prezzo imbattibile. Rispondi per un preventivo.", "offerte", "/contatti" ]
  ].each_with_index do |(summary, body, sender, path), index|
    next if Helpdesk::Request.exists?(project: helpdesk_projects, summary:)

    browser, os, device_type = devices[index % devices.size]
    spam = index >= 16
    written = now - (index * 5 + 1).hours
    request = Helpdesk::Request.new(project: helpdesk_projects[index % helpdesk_projects.size], summary:,
                                    email: sender && "#{sender}@cliente.invalid", page_url: "https://shop.invalid#{path}",
                                    browser:, os:, device_type:, created_at: written, updated_at: written)
    request.assign_attributes(status: :discarded, discarded_at: written + 1.hour, discarded_by: god) if spam
    request.messages.new(direction: :inbound, body:, created_at: written, updated_at: written)
    request.save!
  end
end

# --- Servers: a fake fleet with 24 hours of samples, the same machines bin/demo-agent keeps alive. ---
require Rails.root.join("script/demo_agent/fake_server").to_s
DemoAgent::FakeServer.fleet.each do |server|
  host = Servers::Host.find_or_create_by!(organization: org, fingerprint: server.fingerprint) do |record|
    record.name = server.name
    record.hostname = server.name
    record.groups = server.groups
  end
  next if host.samples.exists?

  rows = 144.downto(1).map do |n|
    at = now - (n * 10).minutes
    Servers::Ingest::Normalize.call(payload: server.payload(at:, journal: false)).sample_attrs
                              .merge(host_id: host.id, organization_id: org.id, recorded_at: at, created_at: at)
  end
  Servers::Sample.insert_all(rows, unique_by: %i[host_id recorded_at])
  Servers::Ingest::Record.call(host:, payload: server.payload(at: now))
  host.update_columns(last_push_at: now)
end

# Link the production web and api machines to their projects (skipped where the project does not allow it).
{ "web-01" => "STR", "web-02" => "STR", "api-01" => "API", "db-01" => "API" }.each do |host_name, key|
  host = Servers::Host.find_by(organization: org, name: host_name)
  project = projects.fetch(key)
  next if host.nil? || Connections::EnvironmentHost.exists?(host:, project:, environment: production)

  link = Connections::EnvironmentHost.new(host:, project:, environment: production, created_by: god)
  puts "  Server link #{host_name} → #{key} skipped: #{link.errors.full_messages.to_sentence}" unless link.save
end

# --- Releases: a version history on every project, the newest live on staging and the one before in production. ---
projects.values.each_with_index do |project, offset|
  count = busy.include?(project) ? 6 : 3
  versions = Array.new(count) { |n| "v1.#{offset}.#{n}" }
  versions.each_with_index do |version, n|
    deployed = now - ((count - n) * 2).days + offset.hours
    %w[staging production].each do |environment|
      next if environment == "production" && n == count - 1

      Projects::Release.find_or_create_by!(project:, version:, environment:) do |release|
        release.sha = Digest::SHA1.hexdigest("#{project.key}-#{version}")
        release.build_time = deployed - 20.minutes
        release.deployed_at = environment == "production" ? deployed + 1.hour : deployed
        release.first_event_at = release.deployed_at + 5.minutes
        release.last_event_at = n == count - 1 ? now : deployed + 2.days
        release.events_count = busy.include?(project) ? rand(20..400) : rand(0..30)
      end
    end
  end
  %w[staging production].each do |environment|
    scope = project.releases.where(environment:)
    # Releases born from error ingest can carry a raw commit SHA: only real versions compete.
    live = scope.select { |release| Gem::Version.correct?(release.version.delete_prefix("v")) }
                .max_by { |release| Gem::Version.new(release.version.delete_prefix("v")) }
    next if live.nil? || live.current?

    scope.update_all(current: false)
    live.update!(current: true)
  end
end

# --- Approvals: every kind of decision waits on god, so the Home queue and the Approvals page are full. ---
# god becomes the organization CTO (only when nobody is): agent plans reach the CTO of their project.
org.update!(cto: god) if org.cto_id.nil?
seed_tickets = Ticketing::Ticket.where(project: projects.values, title: subjects).includes(:status).order(:title).to_a
                                .reject { |ticket| ticket.status.category_done? }
review_status = org.ticket_statuses.find_by(review_gate: true)

# Tickets in review with god as reviewer.
if review_status
  seed_tickets.first(4).each do |ticket|
    ticket.update!(status: review_status, reviewer: god) unless ticket.reviewer_id == god.id
  end
end

# The machine and the service account the example agent work runs on.
robot = Accounts::Account.find_or_create_by!(email: "automator@demo.test") do |account|
  account.name = "Demo automator"
  account.kind = :service
  # Never used to log in: random, shaped to pass the password rules.
  account.password = "#{SecureRandom.base58(20)}aA1!"
end
Connections::Membership.find_or_create_by!(account: robot, organization: org)
agent_host = Agents::Host.find_or_create_by!(organization: org, fingerprint: "seed-automator-demo") do |host|
  host.hostname = "automator-demo"
  host.platform = "linux"
  host.arch = "amd64"
  host.automator_version = "1.0.0"
  host.certified_at = now
end

# One agent work per ticket, each stopped where a person has to decide.
agent_steps = {
  awaiting_approval: { triaged_at: 3.hours.ago, planned_at: 2.hours.ago },
  awaiting_autopilot_approval: { triaged_at: 6.hours.ago, planned_at: 5.hours.ago, approved_at: 5.hours.ago,
                                 autopilot_started_at: 4.hours.ago, autopilot_completed_at: 3.hours.ago,
                                 candidate_verified_at: 3.hours.ago },
  review_blocked: { triaged_at: 4.hours.ago, blocked_at: 1.hour.ago, blocked_kind: "agent_blocked", blocked_phase: "planner",
                    blocked_reason: "Il ticket non dice quale dei due flussi di pagamento va toccato." },
  clarification: { triaged_at: 2.hours.ago }
}
agent_kinds = %i[awaiting_approval awaiting_approval awaiting_approval awaiting_autopilot_approval
                 awaiting_autopilot_approval review_blocked clarification clarification clarification]
seed_tickets.drop(4).first(agent_kinds.size).zip(agent_kinds).each_with_index do |(ticket, kind), index|
  next if ticket.nil? || Agents::Workflow.exists?(ticket:)

  ticket.update!(reviewer: god) if kind == :clarification
  # A delivered candidate puts its ticket in review, as the real delivery does: approving it is a review.
  ticket.update!(status: review_status) if kind == :awaiting_autopilot_approval && review_status
  workflow = Agents::Workflow.create!(ticket:, triage_requested_at: 8.hours.ago, triage_started_at: 7.hours.ago,
                                      **agent_steps.fetch(kind))
  attempt = Agents::Attempt.create!(
    workflow:, organization: org, host: agent_host, service_account: robot, runtime: "claude",
    phase: kind == :awaiting_autopilot_approval ? "autopilot" : "planner",
    skill_key: kind == :awaiting_autopilot_approval ? "/closeyourit-autopilot" : "/closeyourit-planner",
    status: :approved, idempotency_key: "seed-#{ticket.id}", external_run_id: "seed-run-#{index}",
    started_at: 3.hours.ago, finished_at: 2.hours.ago
  )
  if kind.in?(%i[awaiting_approval awaiting_autopilot_approval])
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Riprodurre il caso, correggere la causa e coprirlo con un test.",
                         scenarios: [], definition_of_done: [ "Test verdi", "Nessuna regressione" ], notes: [],
                         ticket_snapshot_digest: "seed")
  end
  next unless kind == :clarification

  question = "Il comportamento va cambiato per tutti o solo per i nuovi utenti?"
  clarification = Agents::Clarification.create!(workflow:, attempt:, asked: [ question ])
  # The questions are rows of their own, written unvalidated as Agents::Clarifications::Ask does.
  Ticketing::Question.new(ticket:, round_id: clarification.id, body: question, position: 1, blocking: true,
                          audience: :internal, origin: :agent, author: ticket.reporter).save(validate: false)
end

# Secret changes on protected environments, asked by admin: god can decide them (four eyes).
if admin
  { "STR" => "STRIPE_SECRET_KEY", "API" => "DATABASE_POOL_SIZE", "DASH" => "SENTRY_DSN" }.each do |key, name|
    project = projects[key]
    next if project.nil? || Secrets::ChangeRequest.exists?(project:, name:, status: :pending)

    Secrets::ChangeRequest.create!(project:, organization: org, environment: production, requested_by: admin,
                                   name:, action: :set, value: "seed-#{SecureRandom.hex(8)}")
  end
end

puts "  Demo data: #{projects.size} projects, rich data on #{org.slug}"
