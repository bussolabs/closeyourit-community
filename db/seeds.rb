# frozen_string_literal: true

# Seed idempotenti (find_or_create_by!) — rieseguibili in ogni ambiente.
# Dati demo solo in development (rules/rails/seeds.md).
puts "Seeding…"

# In produzione la password dell'account privilegiato è OBBLIGATORIA via ENV:
# nessuna credenziale di default deve mai finire in produzione.
# Read only when the account is created, so a self-hosted install can drop GOD_PASSWORD from its
# settings after the first start: the seed runs at every boot (CYRA-919).
god_password = lambda do
  ENV.fetch("GOD_PASSWORD") do
    raise "GOD_PASSWORD è obbligatoria per il seed dell'account god in produzione" if Rails.env.production?

    "Password123!" # solo sviluppo/test (dati locali) — conforme alla policy password
  end
end

# GOD_EMAIL lets a self-hosted install pick its own administrator address (CYRA-916).
# Outside production the address is an example. Production keeps the address its administrator was created
# with until GOD_EMAIL is set there: this seed runs at every boot, so any other default would create a second
# administrator. Delete the production branch once GOD_EMAIL is set (CYRA-1041).
god_email = ENV.fetch("GOD_EMAIL") { Rails.env.production? ? "god@closeyour.it" : "god@example.com" }
god = Accounts::Account.find_or_create_by!(email: god_email) do |account|
  account.name = "CloseYourIt Admin"
  account.god = true
  account.password = god_password.call
end
puts "  God account: #{god.email}"

# Configurazione globale di sistema (riga singola): retention log di default (god-level).
Settings::Global.instance
puts "  Global settings: logs retention #{Settings::Global.instance.logs_retention_days}d"

if Rails.env.development?
  org = Organizations::Organization.find_or_create_by!(slug: "demo") do |organization|
    organization.name = "Demo Organization"
    organization.created_by = god
  end

  Connections::Membership.find_or_create_by!(account: god, organization: org) do |membership|
    membership.role = :owner
  end

  # Dev: riallinea la password del god a quella documentata/prefill (find_or_create_by! sopra
  # non aggiorna la password su un god già esistente da seed precedenti).
  god.update!(password: god_password.call)
  puts "  Demo organization: #{org.slug} (owner: #{god.email})"

  # Status e priority di default per l'organizzazione (stesso service usato dal provisioning god).
  Types::InstallDefaults.call(organization: org, created_by: god)

  # Regole di alerting di default (uptime giù/su): senza, una caduta non avvisa nessuno (CYRA-207).
  Alerting::Rules::InstallDefaults.call(organization: org, created_by: god)

  # Ruoli RBAC default dell'org (Viewer/Triager/Maintainer/Administrator, editabili dall'owner).
  Authorization::InstallDefaultRoles.call(organization: org, created_by: god)

  # Personas dev per il prefill del login (god è già owner sopra; admin/member nella demo).
  Dev::Personas.all.each do |persona|
    next if persona[:email] == god.email

    account = Accounts::Account.find_or_create_by!(email: persona[:email]) do |a|
      a.name = persona[:name]
      a.password = persona[:password]
    end
    # Sincronizza il ruolo anche su membership esistenti (idempotente: corregge il drift seed).
    membership = Connections::Membership.find_or_initialize_by(account: account, organization: org)
    membership.role = persona[:role]
    membership.save!
  end
  puts "  Dev personas: #{Dev::Personas.all.map { |p| p[:email] }.join(', ')}"

  # Progetti demo (idempotenti, con sync drift sui record da seed precedenti).
  projects_data = [
    { key: "STR", name: "Storefront",   color: "indigo",  description: "Frontend pubblico: catalogo, carrello e checkout." },
    { key: "API",   name: "Payments API", color: "emerald", description: "Backend pagamenti REST e webhook." },
    { key: "DASH",  name: "Dashboard",    color: "violet",  description: "Dashboard analytics interna." },
    { key: "CLI",   name: "CLI Tooling",  color: "amber",   description: "CLI e automazioni per sviluppatori." }
  ]
  projects = projects_data.to_h do |data|
    project = Projects::Project.find_or_create_by!(organization: org, key: data[:key]) do |p|
      p.name = data[:name]
      p.created_by = god
    end
    project.update!(name: data[:name], color: data[:color], description: data[:description])
    [ data[:key], project ]
  end

  # Gruppo demo (macro-progetto): raggruppa due progetti. Idempotente.
  group = Projects::Group.find_or_create_by!(organization: org, name: "Storefront Suite") do |g|
    g.created_by = god
    g.color = "indigo"
  end
  projects.fetch("STR").update!(group: group)
  projects.fetch("DASH").update!(group: group)

  # Piattaforme demo: ogni progetto dichiara su cosa gira (idempotente: platforms = [...] sincronizza).
  platform_for = ->(code) { org.platforms.find_by(code: code) }
  {
    "STR" => %w[web ios], "API" => %w[web], "DASH" => %w[web android], "CLI" => %w[web]
  }.each do |key, codes|
    projects.fetch(key).platforms = codes.filter_map { |code| platform_for.call(code) }
  end

  # Profilo: piattaforme che ogni persona usa (pre-selezione nei nuovi ticket).
  { "admin@demo.test" => %w[web], "member@demo.test" => %w[ios web], "customer@demo.test" => %w[ios] }.each do |email, codes|
    Accounts::Account.find_by(email: email)&.update!(platform_codes: codes)
  end

  admin_acc = Accounts::Account.find_by(email: "admin@demo.test")
  member_acc = Accounts::Account.find_by(email: "member@demo.test")
  customer_acc = Accounts::Account.find_by(email: "customer@demo.test")

  # Scoping demo (strict): il member vede il GRUPPO (tutti i suoi progetti, presenti e futuri),
  # il customer vede un solo PROGETTO. admin/god restano unscoped → vedono tutto.
  Connections::GroupMembership.find_or_create_by!(account: member_acc, group: group) if member_acc
  Connections::ProjectMembership.find_or_create_by!(account: customer_acc, project: projects.fetch("API")) if customer_acc

  status_for = ->(code) { org.ticket_statuses.find_by(code: code) }
  priority_for = ->(code) { org.ticket_priorities.find_by(code: code) }

  tickets_data = [
    { key: "STR", title: "Il bottone checkout non risponde su Safari 17", status: "open", priority: "high", assignee: admin_acc,
      given: "Safari 17 con articoli nel carrello", when_step: "clicco Checkout dopo aver cambiato la quantità",
      then_step: "non succede nulla, il bottone è inattivo", expected: "il checkout procede al pagamento" },
    { key: "STR", title: "Il logo è sfocato su display retina", status: "in_review", priority: "low", assignee: member_acc,
      given: "un MacBook con display retina", when_step: "apro la home", then_step: "il logo appare sfocato",
      expected: "il logo è nitido" },
    { key: "API", title: "I retry del webhook duplicano gli ordini", status: "in_progress", priority: "high", assignee: member_acc,
      given: "un webhook di pagamento andato in timeout", when_step: "il provider ritenta la consegna",
      then_step: "l'ordine viene creato due volte", expected: "l'ordine è idempotente" },
    { key: "API", title: "Mancano gli header di rate-limit sul 429", status: "open", priority: "medium", assignee: nil,
      given: "molte richieste in poco tempo", when_step: "ricevo una risposta 429",
      then_step: "non ci sono header Retry-After", expected: "la risposta include gli header di rate-limit" },
    { key: "DASH", title: "Contrasto insufficiente sui badge in dark mode", status: "in_review", priority: "medium", assignee: admin_acc,
      given: "la dashboard in dark mode", when_step: "guardo i badge di stato",
      then_step: "il testo è poco leggibile", expected: "il contrasto rispetta WCAG AA" },
    { key: "DASH", title: "Il grafico non si aggiorna al cambio intervallo", status: "resolved", priority: "low", assignee: member_acc,
      given: "il filtro 'ultimi 7 giorni' attivo", when_step: "passo a 'ultimi 30 giorni'",
      then_step: "il grafico resta invariato", expected: "il grafico si ricarica coi nuovi dati" },
    { key: "CLI", title: "Il token CLI scade troppo presto", status: "closed", priority: "low", assignee: admin_acc,
      given: "una sessione CLI appena avviata", when_step: "uso un comando dopo 10 minuti",
      then_step: "ricevo un errore di token scaduto", expected: "il token dura almeno la sessione" }
  ]
  tickets_data.each do |data|
    attrs = {
      status: status_for.call(data[:status]), priority: priority_for.call(data[:priority]), assignee: data[:assignee]
    }
    scenario_attrs = {
      step_given: data[:given], step_when: data[:when_step], step_then: data[:then_step], step_expected: data[:expected]
    }
    ticket = Ticketing::Ticket.find_or_initialize_by(project: projects.fetch(data[:key]), title: data[:title])
    ticket.reporter ||= god
    ticket.assign_attributes(attrs)
    ticket.scenarios.first_or_initialize(position: 0).assign_attributes(scenario_attrs)
    ticket.save!
  end
  # Demo: piattaforme colpite su un paio di ticket (subset del progetto).
  Ticketing::Ticket.find_by(project: projects.fetch("STR"), title: "Il bottone checkout non risponde su Safari 17")
                   &.update!(platforms: %w[ios web].filter_map { |code| platform_for.call(code) })
  Ticketing::Ticket.find_by(project: projects.fetch("DASH"), title: "Contrasto insufficiente sui badge in dark mode")
                   &.update!(platforms: %w[web].filter_map { |code| platform_for.call(code) })

  ticket_count = Ticketing::Ticket.joins(:project).where(projects: { organization_id: org.id }).count
  puts "  Demo: #{projects.size} progetti, #{ticket_count} ticket"

  # CYRA-929 — example data on every page of the demo organization.
  load Rails.root.join("db/seeds/demo_data.rb")
  load Rails.root.join("db/seeds/review_data.rb")

  # CYRA-929 — an organization with nothing in it, owned by god: the empty states, page by page.
  empty = Organizations::Organization.find_or_create_by!(slug: "empty") do |organization|
    organization.name = "Empty Organization"
    organization.created_by = god
  end
  Connections::Membership.find_or_create_by!(account: god, organization: empty) { |membership| membership.role = :owner }
  Types::InstallDefaults.call(organization: empty, created_by: god)
  Alerting::Rules::InstallDefaults.call(organization: empty, created_by: god)
  Authorization::InstallDefaultRoles.call(organization: empty, created_by: god)
  puts "  Empty organization: #{empty.slug} (owner: #{god.email})"
end

# Backfill RBAC (idempotente, ADDITIVO) per ogni org: ruoli default + team "Administrators" che
# preserva la visibilità degli attuali admin sui progetti esistenti (nuovo regime: solo owner vede
# tutto). Sicuro in ogni ambiente; non rimuove mai link/membri (preserva gli edit dell'owner).
Organizations::Organization.find_each do |organization|
  Authorization::BackfillOrganization.call(organization: organization)
end
puts "  RBAC: ruoli default + backfill Administrators"

puts "Done."
