# frozen_string_literal: true

module Changelog
  # CYRA-445 — L'AREA DI UNA VOCE DEL CHANGELOG, e il suo nome.
  #
  # Una voce non dichiara l'area di cui parla: la dichiara il link interno che porta alla pagina
  # (`[Ticket](/member/tickets)`, obbligatorio per convenzione — vedi CLAUDE.md §Changelog). Da lì
  # si ricava l'area, e quindi il filtro «fammi vedere solo cosa è cambiato qui».
  #
  # Il nome dell'area NON è quello scritto nel file: è quello che quella destinazione ha nel menu
  # (`member.nav.*`). Nel changelog la stessa area era stata chiamata in più modi — «Conoscenza» e
  # «Knowledge», «Disponibilità» e «Uptime», «Rallentamenti» e «Performance», «Agenti AI» e
  # «Assistenti» — e nessuno di quei nomi coincideva col menu: chi leggeva doveva indovinare che
  # due parole diverse indicassero la stessa cosa. Si rinomina la resa, mai il file: le 2700 righe
  # di CHANGELOG.md restano come sono state scritte (regola del glossario di prodotto), e ogni voce
  # nuova eredita il nome giusto senza che nessuno debba ricordarselo.
  #
  # Le guide (`/member/guides…`) non sono un'area: il rimando «([guida](…))» accompagna quasi ogni
  # voce e non dice di cosa quella voce parli. Resta scritto com'è e non entra nei filtri.
  module Areas
    # Link markdown INTERNO: href che inizia con "/" ma non con "//" o "/\" (esclude alla fonte i
    # link esterni, i protocol-relative e gli schemi pericolosi). Stessa regex per il filtro e per la
    # resa: ciò che si può cliccare e ciò che si può filtrare devono essere gli stessi link.
    INTERNAL_LINK = %r{\[([^\]]+?)\]\((/(?![/\\])[^)\s]*)\)}

    # slug (stabile, viaggia nell'indirizzo) → [chiave del nome nel menu, prefissi di path].
    # Un'area nuova si aggiunge QUI: il nome arriva dal menu, non si riscrive a mano.
    REGISTRY = {
      # CYRA-338 — l'area che governa l'organizzazione (membri, team, ruoli, ambienti, piattaforme):
      # si chiamava «Impostazioni», lo stesso nome della pagina delle preferenze personali.
      "administration" => [ "member.nav.group_settings", %w[/member/settings] ],
      # CYRA-745 — il registro attività ha una voce sua nel menu, sotto l'amministrazione: l'area è
      # separata perché una voce che parla di «chi ha fatto cosa» non parla delle impostazioni.
      "activity" => [ "member.nav.activity", %w[/member/activity] ],
      "agents" => [ "member.nav.agents", %w[/member/agents /member/skills] ],
      "alert_channels" => [ "member.nav.alert_channels", %w[/member/alerting/channels] ],
      "alert_rules" => [ "member.nav.alert_rules", %w[/member/alerting/rules] ],
      "alerts" => [ "member.nav.alerts", %w[/member/alerting/notifications] ],
      "analytics" => [ "member.nav.analytics", %w[/member/monitoring/analytics] ],
      # CYRA-593 aveva dato alle lavorazioni in volo una voce e una pagina sue; CYRA-630 le ha
      # riportate dentro le decisioni, come secondo elenco. `/member/workflows` resta qui perché il
      # CHANGELOG lo cita e una voce già pubblicata non si riscrive: l'indirizzo rimanda alla vista
      # nuova, e la sua area è quella dove il contenuto è finito.
      "approvals" => [ "member.nav.group_approvals", %w[/member/home/approvals /member/workflows] ],
      # L'assistente di aiuto si apre da un pannello in barra laterale, non da una voce di menu: come
      # per le novità, il nome è quello con cui il prodotto lo chiama nel pannello stesso.
      "assistant" => [ "member.assistant.panel.title", %w[/member/assistant] ],
      "automation" => [ "member.nav.group_automation", %w[/member/automation] ],
      # Le novità sono una pagina come le altre, e alcune voci parlano proprio di lei: il suo nome
      # non sta nel menu ma nel titolo con cui il prodotto la chiama.
      "changelog" => [ "shared.changelog.page_title", %w[/member/changelog] ],
      "conversations" => [ "member.nav.conversations", %w[/member/chat] ],
      "crons" => [ "member.nav.crons", %w[/member/monitoring/cron] ],
      "databases" => [ "member.nav.databases", %w[/member/monitoring/databases] ],
      "datasets" => [ "member.nav.datasets", %w[/member/datasets] ],
      # CYRA-441 — piattaforme e ambienti sono due voci dell'Amministrazione, e una voce del
      # changelog può parlare proprio di loro: come membri, ruoli e organizzazione, hanno il nome che
      # portano nel menu.
      "environments" => [ "member.nav.environments", %w[/member/environments] ],
      "errors" => [ "member.nav.errors", %w[/member/monitoring/error] ],
      "feature_matrix" => [ "member.nav.feature_matrix", %w[/member/product] ],
      # CYRA-581 — il collegamento con GitHub è una voce dell'Amministrazione come membri, team e
      # ruoli, e una voce di changelog può parlare proprio di lui: prima non aveva un'area perché non
      # aveva nemmeno una voce di menu da cui prendere il nome.
      "github_app" => [ "member.nav.github_app", %w[/member/integrations/github] ],
      "home" => [ "member.nav.home", %w[/member/home] ],
      "ideas" => [ "member.nav.ideas", %w[/member/ideas] ],
      "helpdesk" => [ "member.nav.helpdesk", %w[/member/helpdesk] ],
      # CYRA-545 — l'elenco dei servizi esterni collegati con la chiave dell'organizzazione. Sta
      # DOPO `github_app` nella risoluzione, che è per prefisso più lungo: una voce che parla della
      # pagina della GitHub App resta sua, tutto il resto di `/member/integrations` è quest'area.
      "integrations" => [ "member.nav.integrations", %w[/member/integrations] ],
      "knowledge" => [ "member.nav.knowledge", %w[/member/knowledge] ],
      "logs" => [ "member.nav.logs", %w[/member/monitoring/logs] ],
      "measurements" => [ "member.nav.measurements", %w[/member/monitoring/measurements] ],
      "members" => [ "member.nav.members", %w[/member/members] ],
      "observability" => [ "member.nav.group_observability", %w[/member/observability] ],
      "organization" => [ "member.nav.organization", %w[/member/organization] ],
      "performance" => [ "member.nav.performance", %w[/member/monitoring/performance] ],
      "platforms" => [ "member.nav.platforms", %w[/member/platforms] ],
      # `/account/…` sono le pagine del proprio profilo (verifica in due passaggi, password): per
      # chi legge sono le stesse Preferenze.
      "preferences" => [ "member.nav.preferences", %w[/member/preferences /account] ],
      # CYRA-362 — i gruppi di progetti non sono un'area del menu: ci si arriva dalla lista dei
      # progetti, e la briciola di pane dice «Progetti › Gruppi». Una voce che parla di gruppi parla
      # dell'area Progetti.
      "projects" => [ "member.nav.projects", %w[/member/projects /member/groups] ],
      "replays" => [ "member.nav.replays", %w[/member/monitoring/replays] ],
      "roles" => [ "member.nav.roles", %w[/member/roles] ],
      "servers" => [ "member.nav.servers", %w[/member/monitoring/servers /member/monitoring/tokens] ],
      "session_health" => [ "member.nav.session_health", %w[/member/monitoring/sessions] ],
      "clusters" => [ "member.nav.clusters", %w[/member/monitoring/clusters] ],
      "status_page" => [ "member.nav.status_page", %w[/member/monitoring/status /member/monitoring/status_pages] ],
      # I team stanno accanto a Membri e Ruoli nell'Amministrazione, e come loro hanno una pagina che
      # una voce di changelog può citare: mancava soltanto qui, e la prima voce che l'ha linkata ha
      # fatto cadere la guardia di copertura al rilascio.
      "teams" => [ "member.nav.teams", %w[/member/teams] ],
      "tickets" => [ "member.nav.tickets", %w[/member/tickets] ],
      "todos" => [ "member.nav.todos", %w[/member/lists] ],
      "traces" => [ "member.nav.traces", %w[/member/monitoring/traces] ],
      "uptime" => [ "member.nav.uptime", %w[/member/monitoring/monitors /member/monitoring/groups] ],
      # CYRA-641 — secret files are Vault pages like variables, and a changelog entry may cite them:
      # they live under `/files`, a prefix of their own.
      "vault" => [ "member.nav.group_vault", %w[/member/vault /member/personal/secrets /member/shared/secrets
                                                /member/personal/files /member/shared/files] ],
      # CYRA-535 — SEO è diventata un'area con quattro voci: il nome che una voce di changelog deve
      # portare è quello dell'area, non più quello dell'unica voce che c'era.
      "seo" => [ "member.nav.group_seo", %w[/member/monitoring/seo /member/monitoring/sites] ],
      "vulnerabilities" => [ "member.nav.vulnerabilities", %w[/member/monitoring/vulnerabilities] ],
      "workload" => [ "member.nav.workload", %w[/member/workload] ]
    }.freeze

    # Ogni prefisso con la sua area, dal più lungo al più corto: `/member/home/approvals` è le
    # approvazioni, `/member/home` è la Home, e a decidere è il prefisso più specifico.
    PREFIXES = REGISTRY.flat_map { |slug, (_, paths)| paths.map { |path| [ path, slug ] } }
                       .sort_by { |path, _| -path.length }
                       .freeze

    module_function

    # L'area di una destinazione, o nil se quel path non è un'area (guide comprese).
    def slug_for_path(path)
      clean_path = path.to_s.split("?").first.to_s.chomp("/")
      _, slug = PREFIXES.find { |prefisso, _| clean_path == prefisso || clean_path.start_with?("#{prefisso}/") }
      slug
    end

    # Il nome che l'area ha nel menu, o nil se lo slug non esiste.
    def label(slug, locale: I18n.locale)
      key, = REGISTRY[slug.to_s]
      key && I18n.t(key, locale: locale)
    end

    # Il nome di menu di una destinazione, o nil dove non c'è un'area da nominare.
    def label_for_path(path, locale: I18n.locale)
      slug = slug_for_path(path)
      slug && label(slug, locale: locale)
    end

    # Le aree citate da una voce, nell'ordine in cui compaiono e senza ripetizioni.
    def in_entry(text)
      text.to_s.scan(INTERNAL_LINK).filter_map { |_, path| slug_for_path(path) }.uniq
    end

    # Gli slug riconosciuti fra quelli arrivati dall'indirizzo: un valore inventato si ignora,
    # non svuota la pagina.
    def known(slugs)
      Array(slugs).map(&:to_s).select { |slug| REGISTRY.key?(slug) }.uniq
    end

    # Opzioni del filtro: [nome, slug] in ordine alfabetico di nome, come si leggono.
    def options
      REGISTRY.keys.map { |slug| [ label(slug), slug ] }.sort_by { |name, _| name.to_s }
    end
  end
end
