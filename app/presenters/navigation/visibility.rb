# frozen_string_literal: true

module Navigation
  # CYRA-740 — quali voci del menu member vale la pena mostrare a chi sta guardando. UN oggetto solo
  # per richiesta (NavigationVisibility#navigation_visibility): la barra laterale contiene TUTTI i
  # gruppi in ogni pagina e attraversa la stessa voce più volte per render, quindi ogni condizione qui
  # dentro si valuta una volta e si ricorda.
  #
  # CYRA-799 — due collaboratori, ricevuti nel costruttore: `visible` dice che cosa vede chi sta
  # guardando (Authorization::VisibleScope), `permissions` che cosa gli è permesso. Prima erano
  # diciotto metodi PRIVATI del controller presi in prestito con `send`, e chi apriva il file non
  # vedeva da dove arrivassero. Questo oggetto decide COSA vale la pena mostrare; CHI può aprire una
  # pagina resta deciso dai gate RBAC, che non passano di qui — un URL digitato risponde come prima.
  class Visibility
    # `permissions` è la facciata PUBBLICA del controller (la stessa che usano le viste): in un
    # controller un metodo pubblico è un'azione, quindi i gate restano privati e si interrogano da
    # lì. `can?` lascia il segno letto dalla rete di CYRA-727, come quando lo chiama una pagina.
    def initialize(visible:, permissions:)
      @visible = visible
      @permissions = permissions
    end

    # --- Il menu di un cliente esterno (CYRA-586) --------------------------------------------
    # Un cliente esterno non lavora AL sistema: non accende monitor, non manda log, non tiene chiavi,
    # non prepara dati per l'AI. Il menu però gli mostrava le aree tecniche come a chiunque altro, e
    # quasi ognuna lo portava su una pagina vuota — i dati sono filtrati correttamente (vede solo i
    # suoi progetti), il difetto era la promessa. È la stessa regola del gruppo rimasto con la sola
    # panoramica (CYRA-29), estesa dal vuoto per permessi al vuoto per costruzione.
    #
    # Il ruolo di membership, qui, NON autorizza niente: decide cosa vale la pena mostrare. I gate di
    # accesso restano quelli RBAC (`require_permission!`), il filtro sui dati resta dov'era.
    def customer_actor? = permissions.current_membership&.customer? || false

    # Vero per chiunque lavori nel team; per un cliente esterno solo se l'area ha già del contenuto
    # suo. Il gate sul contenuto vale SOLO per lui: per il team una lista vuota è la pagina che
    # insegna ad accendere la funzione (CYRA-376), e nasconderla toglierebbe l'unico posto da cui si
    # comincia. Memoizzato per chiave: la sidebar è una sola e ogni render la attraversa più volte.
    def customer_content_gate(key)
      permissions.note_permission_check!
      return true unless customer_actor?

      @customer_content_gates ||= {}
      return @customer_content_gates[key] if @customer_content_gates.key?(key)

      @customer_content_gates[key] = yield
    end

    def errors_nav_visible?
      customer_content_gate(:errors) { visible.error_groups.exists? }
    end

    def performance_nav_visible?
      customer_content_gate(:performance) { visible.metric_groups.exists? }
    end

    def logs_nav_visible?
      customer_content_gate(:logs) { visible.logs.exists? }
    end

    def vulnerabilities_nav_visible?
      customer_content_gate(:vulnerabilities) { visible.vulnerabilities.exists? }
    end

    def traces_nav_visible?
      customer_content_gate(:traces) { visible.traces.exists? }
    end

    def measurements_nav_visible?
      customer_content_gate(:measurements) { ::Measurements::Series.where(project_id: visible.projects.select(:id)).exists? }
    end

    def session_health_nav_visible?
      customer_content_gate(:session_health) do
        projects = visible.projects.select(:id)
        ::SessionHealth::Session.where(project_id: projects).exists? || ::SessionHealth::Aggregate.where(project_id: projects).exists?
      end
    end

    # CYRA-376 ha rimesso le registrazioni in elenco anche dove nessun progetto registra: la pagina
    # vuota è quella che insegna ad accendere la funzione. A un cliente esterno quella lezione non
    # serve — ad accenderla è il team — quindi per lui la voce vale solo con registrazioni sue.
    def replays_nav_visible?
      customer_content_gate(:replays) { visible.replay_sessions.exists? }
    end

    # Uptime e pagina di stato condividono il gate: la seconda mostra quali dei monitor visibili sono
    # pubblicati, quindi senza monitor non ha niente da dire nemmeno lei.
    def uptime_nav_visible?
      customer_content_gate(:uptime) { visible.monitors.exists? }
    end

    def crons_nav_visible?
      customer_content_gate(:crons) { visible.cron_monitors.exists? }
    end

    # Casella personale: per un cliente esterno compare quando ha davvero ricevuto qualcosa (le regole
    # che generano gli avvisi le scrive il team). Stesso scope del controller: le proprie, in-app.
    def alert_notifications_nav_visible?
      customer_content_gate(:alert_notifications) do
        Current.account.present? && Current.organization.present? &&
          ::Alerting::Notification.exists?(account_id: Current.account.id,
                                           organization_id: Current.organization.id, via: :in_app)
      end
    end

    # La cassaforte è uno strumento del team: le chiavi di progetto stanno dietro permessi che un
    # cliente esterno non ha, e le altre pagine dell'area (personale, cosa puoi fare qui) non sono un
    # posto in cui lavora. Qui il gate sul contenuto non servirebbe: senza il primo segreto la voce
    # non comparirebbe mai, e non ci sarebbe nessun posto da cui crearlo.
    def vault_nav_visible? = !customer_actor?

    # Gata la voce sidebar "SEO": compare dove il SEO ha senso, cioè dove esiste almeno un progetto
    # con una piattaforma web. Non basta guardare i siti già dichiarati — con quel gate la voce non
    # comparirebbe mai, e non ci sarebbe nessun posto da cui creare il primo.
    #
    # Per un cliente esterno il gate si stringe sui siti già dichiarati (CYRA-586): il primo sito lo
    # crea il team, quindi «da dove si comincia» non è un problema suo — e senza siti l'area sarebbe
    # tre pagine vuote.
    def seo_nav_visible?
      return @seo_nav_visible if defined?(@seo_nav_visible)

      @seo_nav_visible = visible.projects.analytics_capable.exists? &&
                         customer_content_gate(:seo) { visible.seo_sites.exists? }
    end

    # Gata la voce sidebar "Datasets" (sezione AI): compare se l'utente vede almeno un progetto. Mai
    # per un cliente esterno (CYRA-586): preparare gli esempi per un modello è lavoro del team, e con
    # zero dataset la voce sul contenuto non comparirebbe mai — resterebbe una porta senza stanza.
    def datasets_nav_visible?
      return @datasets_nav_visible if defined?(@datasets_nav_visible)

      @datasets_nav_visible = !customer_actor? && visible.projects.exists?
    end

    # Gata la voce sidebar "Ricerca variabili" (Vault, CYRA-137): la ricerca è cross-progetto tra i
    # visibili — zero progetti visibili = niente da cercare. Nessun permesso richiesto (a differenza
    # di vault_audit, gated secrets_audit.view): la ricerca non espone valori, solo la presenza del
    # nome, quindi il gate è la sola visibilità progetti come per datasets_nav_visible?. Memoizzato.
    def vault_variable_search_nav_visible?
      return @vault_variable_search_nav_visible if defined?(@vault_variable_search_nav_visible)

      @vault_variable_search_nav_visible = visible.projects.exists?
    end

    # Gata la voce sidebar "Richieste in attesa" (Vault, CYRA-138 C2b): vero se l'account gestisce
    # (secrets.manage) almeno un progetto visibile — deve poter raggiungere la pagina anche quando al
    # momento non c'è nulla da decidere — OPPURE se ha almeno una propria richiesta ancora pending (può
    # sempre ritirarla, anche se nel frattempo ha perso secrets.manage sul progetto). A differenza di
    # vault_variable_search_nav_visible? (un semplice `.exists?`) la condizione è composta: i progetti
    # visibili si caricano UNA SOLA VOLTA (variabile locale) e si riusano per entrambi i rami — altrimenti
    # la seconda chiamata (branch richiedente) ripeterebbe la query. Stesso gate usato dal controller
    # (Member::Vault::ChangeRequestsController#require_change_requests_view): single source of truth.
    def vault_change_requests_nav_visible?
      return @vault_change_requests_nav_visible if defined?(@vault_change_requests_nav_visible)

      projects = visible.projects.to_a
      @vault_change_requests_nav_visible =
        projects.any? { |project| permissions.can?("secrets.manage", scope: project) } ||
        requester_of_pending_change?(projects)
    end

    # The "Help desk" entry: shown to whoever holds helpdesk.manage on at least one visible project.
    # `order` turns the organization's association into a plain query: on a page that loads the
    # organization with strict_loading (project moves), reading the association itself raises. Memoized.
    def helpdesk_nav_visible?
      return @helpdesk_nav_visible if defined?(@helpdesk_nav_visible)

      @helpdesk_nav_visible = visible.projects.order(:id).any? { |project| permissions.can?("helpdesk.manage", scope: project) }
    end

    # Gata la voce "Workload" nella sidebar member: compare solo se l'account è in ≥1 team. Memoizzato.
    def workload_nav_visible?
      return @workload_nav_visible if defined?(@workload_nav_visible)

      @workload_nav_visible = visible.teams.exists?
    end

    # Gata la voce "Agents" nella sidebar member (sezione AI): org-gated dal permesso, non scope-svuotata.
    # Memoizzato per richiesta.
    def agents_nav_visible?
      return @agents_nav_visible if defined?(@agents_nav_visible)

      @agents_nav_visible = permissions.can_view_agents?
    end

    # Gata la voce "Servers" nella sidebar member (a differenza delle altre voci Monitor la risorsa è
    # org-gated dal permesso, non scope-svuotata). Memoizzato per richiesta.
    def servers_nav_visible?
      return @servers_nav_visible if defined?(@servers_nav_visible)

      @servers_nav_visible = permissions.can_view_servers?
    end

    # Vero se l'utente può vedere la pagina gruppi uptime → gata il bottone "Groups" nell'header Uptime.
    def uptime_groups_nav_visible? = permissions.can_view_uptime_groups?

    # Gata la voce "Analytics" nella sidebar member: compare solo se l'utente vede ≥1 progetto che
    # raccoglie analytics (piattaforma web + toggle "Raccogli analytics" attivo). Memoizzato per richiesta.
    def analytics_nav_visible?
      return @analytics_nav_visible if defined?(@analytics_nav_visible)

      @analytics_nav_visible = visible.projects.analytics_collecting.exists?
    end

    # Gata la voce "Replays" nella sidebar member: compare solo se l'utente vede ≥1 progetto che
    # registra il session replay (piattaforma web + toggle attivo). Memoizzato per richiesta.
    def session_replay_nav_visible?
      return @session_replay_nav_visible if defined?(@session_replay_nav_visible)

      @session_replay_nav_visible = visible.projects.session_replay_collecting.exists?
    end

    # Gata la voce "Matrice funzionalità" nella sidebar Product: serve il permesso E almeno un
    # macro-progetto visibile (senza prodotti la pagina sarebbe vuota). Memoizzato per richiesta: la
    # sidebar contiene TUTTI i gruppi in ogni pagina, non più le sole voci dell'area attiva.
    def product_matrix_nav_visible?
      return @product_matrix_nav_visible if defined?(@product_matrix_nav_visible)

      @product_matrix_nav_visible = permissions.can_view_product_features? && visible.groups.exists?
    end

    private

    attr_reader :visible, :permissions

    # True se l'account corrente ha richiesto almeno una Secrets::ChangeRequest ancora pending tra i
    # progetti passati (già scoped anti-BOLA a monte da visible.projects). Safe-nav su
    # Current.account: nil → false esplicito, MAI un requested_by_id nil che matcherebbe le CR con
    # richiedente nullificato (account cancellato) di un altro utente.
    def requester_of_pending_change?(projects)
      return false if Current.account.nil? || projects.empty?

      ::Secrets::ChangeRequest.pending.exists?(requested_by_id: Current.account.id, project_id: projects.map(&:id))
    end
  end
end
