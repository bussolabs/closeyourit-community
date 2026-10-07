# frozen_string_literal: true

module Navigation
  # Registro statico dei nodi di primo livello della sidebar member. Erede di Navigation::Space
  # (CYRA-133/139), con un cambio di natura (CYRA-521): gli space sceglievano QUALI voci mostrare, e
  # una pagina che apparteneva a un'area diversa da quella che la linkava riscriveva il menu sotto le
  # dita — partendo dalla Home e premendo Ticket sparivano le voci di fianco a quella appena premuta.
  # Qui la sidebar è UNA sola, uguale ovunque: questo registro dice com'è fatta, non quale mostrare.
  #
  # La MEMBERSHIP sopravvive perché serve ancora a due cose, nessuna delle quali può riscrivere il
  # menu: aprire da solo il gruppo che contiene la pagina aperta (anche via deep-link) e dare alla
  # briciola di pane il livello dell'area. `spec/models/navigation/group_coverage_spec.rb` fallisce
  # se un controller member nuovo resta fuori.
  #
  # COSTANTE, non tabella CRUD — pattern Monitoring::Tool, eccezione enum-static di
  # rules/lookup-tables.md: aggiungere un nodo = lavoro dev, non dato utente. `label` via i18n
  # (member.nav.group_<id>); qui vive solo la struttura.
  class Group
    # Le tre macro-sezioni, nell'ordine in cui compaiono. Sono etichette, non nodi: non si aprono,
    # non si premono, non hanno una pagina.
    SECTIONS = %w[work system account].freeze

    # `section: nil` = voce fissa in cima, fuori da ogni macro-sezione e da ogni gruppo: le cinque
    # cose che si aprono ogni giorno restano a un clic da qualsiasi punto del prodotto.
    # `children: false` = nodo senza figli (voce semplice): si preme e porta alla sua pagina, non si
    # espande. Un nodo con una destinazione sola non è un gruppo — è quella pagina (CYRA-334).
    REGISTRY = {
      "home" => { icon: "house", section: nil, children: false },
      "approvals" => { icon: "circle-check", section: nil, children: false },
      "conversations" => { icon: "messages-square", section: nil, children: false },
      "todos" => { icon: "list-check", section: nil, children: false },
      "guides" => { icon: "book", section: nil, children: false },
      "projects" => { icon: "folder", section: "work", children: false },
      "product" => { icon: "clipboard-check", section: "work", children: true },
      "knowledge" => { icon: "book-open", section: "work", children: true },
      "observability" => { icon: "gauge", section: "system", children: true },
      "infrastructure" => { icon: "server", section: "system", children: true },
      # CYRA-903 — rules, received alerts and delivery channels are one chain: they left Infrastructure,
      # which had grown to nine entries.
      "alerts" => { icon: "bell", section: "system", children: true },
      "automation" => { icon: "bot", section: "system", children: true },
      # SEO fuori da Osservabilità: qui non si guarda se il sistema sta in piedi, ma se il sito si fa
      # trovare. Le statistiche del sito stanno DENTRO (CYRA-535): erano un nodo per una pagina sola,
      # qui accanto, e le due rispondono alla stessa domanda in due tempi — chi PUÒ arrivare sul
      # sito, e chi ci è arrivato davvero. Da voci lontane, chi apriva l'una aveva metà della
      # risposta e nessun indizio che esistesse l'altra metà.
      "seo" => { icon: "file-search", section: "system", children: true },
      "vault" => { icon: "vault", section: "account", children: true },
      # CYRA-911 — `subnav: true`: the area's pages list their sections on the left, so the sidebar
      # shows one entry that opens the overview instead of a dropdown with ten leaves.
      "settings" => { icon: "settings", section: "account", children: true, subnav: true }
    }.freeze

    # Nodo su cui ricade un id ignoto o manomesso: la Home, che esiste sempre.
    FALLBACK_ID = "home"

    # Controller → nodo. Match esatto oppure per prefisso seguito da slash; a parità, vince il path
    # più lungo (così member/home/approvals va sulla sua voce e non sulla Home che lo contiene).
    MEMBERSHIP = {
      # member/overviews è qui solo perché la guardia di copertura non lo veda orfano: il suo nodo vero
      # arriva dal group_id di route e lo risolve GroupContext, che ha la precedenza su questa mappa.
      #
      # member/searches (CYRA-634) sta con `home` per la stessa ragione di member/quick_add: e' una
      # superficie trasversale, raggiungibile da qualsiasi punto dalla barra comandi e senza un'area
      # propria. Non e' esente dalla guardia — ha rotta (/search) e vista, quindi ci si atterra e senza
      # nodo la briciola salterebbe il livello dell'area.
      "home" => %w[home member/home/cards member/quick_add member/coworkers member/coworker_runs member/coworker_activity member/coworker_proposals
                   member/coworker_rules member/coworker_schedules member/coworker_watches member/coworker_memory_notes
                   member/coworker_budgets member/coworker_controls member/coworker_procedures member/coworker_connections
                   member/coworker_sites member/coworker_devices member/preferences member/saved_views
                   member/page_header_preferences member/dismissed_notices member/support_requests
                   member/organization_switches member/changelog member/errors member/base
                   member/ai member/assistant_conversations member/assistant_messages member/assistant_proposals
                   member/assistant_voice member/assistant_dictation
                   member/overviews member/searches],
      "approvals" => %w[member/home/approvals member/home/approval_counts member/home/workflow_cancellations],
      "conversations" => %w[member/chat_conversations member/chat_messages member/chat_mutes
                            member/alerting_preferences
                            member/telegram_connections member/telegram_groups],
      "todos" => %w[member/todo_lists],
      "guides" => %w[member/guides member/guides/installation],
      # I progetti e tutto ciò che si apre da dentro un progetto: la voce è una sola, ma le pagine di
      # dettaglio sono molte e senza questa riga resterebbero senza area nella briciola.
      "projects" => %w[member/projects member/groups member/group_guidance
                       member/group_guidance_procedures member/group_guidance_references
                       member/project_documents member/project_environments
                       member/project_environment_capabilities member/project_github
                       member/project_guidance member/project_guidance_procedures member/project_usage
                       member/project_guidance_references member/project_milestones
                       member/project_helpdesk_requests
                       member/project_servers member/project_settings member/project_source_versions
                       member/project_tokens member/project_moves],
      "product" => %w[member/tickets member/ideas member/workload member/helpdesk_requests],
      # Knowledge + Book + matrice funzionalità: era lo space "product", che si chiamava quasi come il
      # gruppo "Prodotto" qui accanto e conteneva l'esatto contrario di quel che il nome prometteva
      # (CYRA-330). Ora il nome dice il contenuto.
      "knowledge" => %w[member/knowledge member/product],
      "observability" => %w[member/monitoring/traces member/monitoring/measurements member/monitoring/measurement_rules
                              member/monitoring/session_health member/monitoring/error_groups member/monitoring/metric_groups
                            member/monitoring/log_entries member/monitoring/replays
                            member/monitoring/vulnerabilities],
      "infrastructure" => %w[member/monitoring/monitors member/monitoring/cron_monitors
                             member/monitoring/servers member/monitoring/server_tokens
                             member/monitoring/server_databases member/monitoring/databases
                             member/monitoring/server_actions member/monitoring/incidents
                             member/monitoring/status_pages member/monitoring/uptime_groups
                             member/monitoring/clusters member/monitoring/cluster_nodes
                             member/monitoring/cluster_workloads member/monitoring/cluster_problems
                             member/monitoring/cluster_namespaces],
      "alerts" => %w[member/alerting_rules member/alerting_notifications member/alerting_channels],
      "automation" => %w[member/datasets member/agents member/skill_bundles],
      # Analytics era uno spazio intero per una pagina sola (CYRA-455), poi un nodo di primo livello
      # per la stessa pagina sola: da CYRA-535 è una voce dentro SEO. `member/monitoring/analytics`
      # copre per prefisso anche analytics/goals e analytics/shares.
      "seo" => %w[member/monitoring/seo member/monitoring/seo_sites member/monitoring/analytics],
      "vault" => %w[member/vault member/vault_projects member/personal_secrets
                    member/personal_secret_assets member/personal_secret_versions
                    member/shared_secrets member/shared_secret_assets member/project_secrets
                    member/project_secret_assets member/project_secret_versions
                    member/project_secret_overrides member/project_secret_events],
      # CYRA-581 — `member/integrations` (la GitHub App) stava fra i progetti perché da lì la si
      # raggiungeva: ma è installata sull'ORGANIZZAZIONE, si apre col permesso che governa
      # l'organizzazione e da lì si scollega per tutti. Sotto i progetti la briciola annunciava
      # l'area sbagliata e nel menu si accendeva una voce che porta altrove.
      # CYRA-745 — il registro attività sta qui perché la sua voce vive fra le impostazioni
      # dell'organizzazione: è una domanda sull'organizzazione intera, non su una singola area.
      "settings" => %w[member/activity
                       member/members member/invitations member/service member/teams member/roles
                       member/platforms member/environments member/organizations
                       member/organization_guidance member/organization_ai member/organization_guidance_procedures
                       member/organization_guidance_references member/integrations]
    }.freeze

    def self.ids = REGISTRY.keys
    def self.all = ids.map { |id| new(id) }
    def self.known?(id) = REGISTRY.key?(id.to_s)
    def self.find(id) = known?(id) ? new(id.to_s) : new(FALLBACK_ID)

    # Le voci fisse in cima, nell'ordine della sidebar.
    def self.pinned = all.select(&:pinned?)

    # I nodi raggruppati per macro-sezione, nell'ordine dichiarato in SECTIONS. Le voci fisse non
    # compaiono: stanno sopra le sezioni.
    def self.sections
      SECTIONS.index_with { |section| all.select { |group| group.section == section } }
    end

    # Nodo di appartenenza di un controller, o nil se la pagina non è dell'area member. Match esatto o
    # per prefisso; a parità vince la dichiarazione più lunga, così un sotto-controller con una voce
    # propria non viene assorbito dal ramo che lo contiene.
    def self.for_controller(controller_path)
      best = MEMBERSHIP.flat_map { |id, paths| paths.map { |path| [ id, path ] } }
                           .select { |_, path| controller_path == path || controller_path.start_with?("#{path}/") }
                           .max_by { |_, path| path.length }

      best && new(best.first)
    end

    attr_reader :id

    def initialize(id)
      @id = id.to_s
    end

    def icon = REGISTRY.dig(id, :icon)
    def section = REGISTRY.dig(id, :section)
    def label = I18n.t("member.nav.group_#{id}")

    # Una voce fissa sta in cima, fuori dalle macro-sezioni: è la sola distinzione strutturale fra i
    # nodi, tutto il resto (avere figli o no) è una proprietà del contenuto.
    def pinned? = section.nil?
    def children? = REGISTRY.dig(id, :children)
    def subnav? = REGISTRY.dig(id, :subnav) || false

    def ==(other) = other.is_a?(Group) && other.id == id
    alias_method :eql?, :==
    def hash = id.hash
  end
end
