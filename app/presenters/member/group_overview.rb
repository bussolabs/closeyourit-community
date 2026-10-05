# frozen_string_literal: true

module Member
  # CYRA-334 — le pagine d'ingresso delle aree ripetevano gli stessi collegamenti già visibili nel
  # menu di fianco: si entrava, non si imparava niente e bisognava cliccare ancora. Contraddicevano
  # il principio del prodotto — i dati sono l'interfaccia — proprio nel punto in cui una persona
  # chiede «com'è messa quest'area?».
  #
  # LA REGOLA, uguale per tutte: ogni area apre con i suoi numeri vivi, letti dagli stessi scope
  # visibili delle pagine di destinazione (mai una seconda sorgente che diverge). L'unica eccezione
  # è dichiarata e si spiega da sé: un'area con una destinazione sola non è un'area, è quella pagina
  # — e ci porta dritto (Member::OverviewsController#single_destination).
  class GroupOverview
    Count = Data.define(:key, :value, :tone)

    def initialize(group:, organization:, visible_projects:, visible_tickets:, visible_ideas:,
                   visible_seo_issues: nil, visible_seo_sites: nil)
      @group = group
      @organization = organization
      @visible_projects = visible_projects
      @visible_tickets = visible_tickets
      @visible_ideas = visible_ideas
      @visible_seo_issues = visible_seo_issues
      @visible_seo_sites = visible_seo_sites
    end

    # I conteggi dell'area: il totale di ciò che contiene e, quando esiste, ciò che chiede attenzione.
    # Un'area senza conteggi definiti torna [] e la pagina resta com'era: meglio nessun numero che un
    # numero inventato.
    def counts
      case @group.id
      when "observability" then observability
      when "infrastructure" then infrastructure
      when "product" then product
      when "seo" then seo
      when "settings" then settings
      else []
      end
    end

    private

    def project_ids = @visible_projects.select(:id)

    def observability
      groups = ::Errors::Group.where(project_id: project_ids)
      monitor = ::Uptime::Monitor.where(project_id: project_ids)
      [ Count.new(key: "errors", value: groups.status_unresolved.count, tone: :rose),
        Count.new(key: "monitors_down", value: monitor.where(current_status: :down).count, tone: :rose),
        Count.new(key: "monitors", value: monitor.count, tone: :neutral) ]
    end

    def infrastructure
      hosts = ::Servers::Host.where(organization_id: @organization.id)
      [ Count.new(key: "servers", value: hosts.count, tone: :neutral),
        Count.new(key: "servers_down", value: hosts.where(status: :down).count, tone: :rose) ]
    end

    # CYRA-521 — questi conteggi stavano sotto lo space "product", che però conteneva la conoscenza:
    # la pagina d'ingresso della base di conoscenza apriva contando ticket e idee. Ora stanno dove il
    # nome li promette. La conoscenza non ha conteggi propri e resta senza: meglio nessun numero che
    # un numero che parla d'altro.
    def product
      # "Aperti" = tutto ciò che non è concluso: la categoria dello stato è la stessa lettura che usa
      # la lista dei ticket, non un secondo criterio che col tempo diverge.
      open_records = @visible_tickets.joins(:status).where.not(types_ticket_statuses: { category: :done })
      [ Count.new(key: "tickets_open", value: open_records.count, tone: :amber),
        Count.new(key: "ideas_open", value: @visible_ideas.status_open.count, tone: :neutral) ]
    end

    # CYRA-535 — l'area SEO apre coi rilievi ancora aperti, non con quanti siti sono dichiarati:
    # dichiarare un sito è configurazione fatta una volta, i rilievi aperti sono la cosa che chiede
    # attenzione. Dagli stessi scope visibili dei controller, mai da una seconda sorgente. Se il
    # chiamante non li passa (nessun controller lo fa oggi) l'area resta senza numeri, come le altre
    # non coperte: meglio nessun numero che un numero che parla d'altro.
    def seo
      return [] if @visible_seo_issues.nil? || @visible_seo_sites.nil?

      open_records = @visible_seo_issues.status_open
      [ Count.new(key: "seo_issues_open", value: open_records.count, tone: :amber),
        Count.new(key: "seo_issues_critical", value: open_records.severity_critical.count, tone: :rose),
        Count.new(key: "seo_sites", value: @visible_seo_sites.count, tone: :neutral) ]
    end

    # CYRA-556 — il numero sotto «Persone» comprendeva anche le utenze che usano i programmi: quattro
    # su tredici non erano colleghi, e l'etichetta prometteva persone che non esistono. Sono due
    # popolazioni diverse e ora sono due numeri, letti dallo stesso elenco delle membership.
    def settings
      members = @organization.memberships.joins(:account)
      [ Count.new(key: "members", value: members.merge(::Accounts::Account.human).count, tone: :neutral),
        Count.new(key: "service_accounts", value: members.merge(::Accounts::Account.service).count, tone: :neutral),
        Count.new(key: "projects", value: @visible_projects.count, tone: :neutral) ]
    end
  end
end
