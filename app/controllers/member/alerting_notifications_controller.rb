# frozen_string_literal: true

module Member
  # Notification center personale: l'utente vede/gestisce SOLO le proprie notifiche in-app.
  # Non gated da alerts.manage (è la propria casella, baseline come "vedere lo scope").
  class AlertingNotificationsController < Member::BaseController
    permission_not_required "Casella personale: ognuno vede e gestisce soltanto le proprie notifiche in-app."

    before_action :set_notification, only: %i[read destroy]

    def index
      # CYRA-478 — filtri server-side: con centinaia di non lette su oltre cento pagine, senza un
      # taglio il guasto vero resta sepolto. Tipo di evento e progetto tagliano l'elenco; lo stato di
      # lettura è sulla notifica.
      # :project precaricato (CYRA-747): ogni riga mostra la chiave del suo progetto, che senza
      # preload è una query per notifica — e la casella si legge a pagine da decine di righe.
      # :subject too: each row composes its link from it (Notifications::Link).
      scope = filtered_notifications.includes(:project, :subject).recent
      # CYRA-488 — separazione per natura (sistemi / ticket / agenti). Filtra sulla colonna event_type
      # della notifica stessa, non via join sulla regola: i ticket_*/chat_* hanno rule_id nil e passano
      # comunque. Vocabolario chiuso: una natura inventata dà [] → nessun filtro.
      scope = scope.where(event_type: nature_event_types) if nature_event_types.any?
      scope = scope.unread if params[:read] == "unread"
      scope = scope.where.not(read_at: nil) if params[:read] == "read"
      @pagination = paginate(scope)
      @notifications = @pagination.records
      @groups = Alerting::NotificationGroup.group(@notifications)
      # F115 — a down alert says when the same thing came back, so the two rows read as one story.
      @recoveries = Alerting::Recoveries.for(@notifications)
      # CYRA-315 — i numeri raccontano ciò che stai guardando, non tutto lo scaffale: chi arriva dalla
      # Home ha appena letto «185» e qui deve ritrovare 185. Il chip conta le non lette del taglio
      # attivo (natura compresa), le schede quelle dello stesso taglio senza la natura — così nessun
      # numero in pagina contraddice l'altro.
      @unread_count = unread_count_for(nature_event_types.any? ? scope_by_nature : filtered_notifications)
      @total_unread = unread_count_for(filtered_notifications)
      # CYRA-488 — non lette per natura, per i badge delle schede: una sola query aggregata per
      # event_type, poi ricondotta alla natura via catalogo.
      @nature_unread = nature_unread_counts
      # Ore silenziose dell'utente: se configurate, l'header le segnala con l'orario (CYRA-479).
      @preference = ::Alerting::Preference.for(account: Current.account, organization: Current.organization)
      @projects = visible.projects.order(:name)
      # CYRA-813 — il taglio attivo (sempre) e la macchina da cui si arriva (solo a chi può leggere
      # la flotta): la pagina dice comunque che sta guardando una macchina sola, il nome lo aggiunge
      # chi ha il permesso.
      @host_filter_id = host_filter_id
      @filtered_host = filtered_host
    end

    # Marca letto l'intero gruppo raggruppato in index (params[:ids] = gli altri id della riga):
    # own_notifications filtra eventuali id estranei, quindi nessun rischio anti-BOLA anche se forgiati.
    def read
      own_notifications.where(id: [ @notification.id, *Array(params[:ids]) ]).update_all(read_at: Time.current)
      redirect_to member_alerting_notifications_path
    end

    # CYRA-898 — the bell's panel: the latest five, loaded into a lazy frame of the top bar. No
    # layout: the page around it holds the same frame id, and Turbo would pick that empty one.
    def preview
      @notifications = own_notifications.includes(:subject).recent.limit(5)
      render layout: false
    end

    # Back to where it was pressed: the bell's panel lives on every page (CYRA-898).
    def read_all
      own_notifications.unread.update_all(read_at: Time.current)
      redirect_back_or_to member_alerting_notifications_path, notice: t("member.alerting.notifications.all_read")
    end

    def destroy
      @notification.destroy
      redirect_to member_alerting_notifications_path
    end

    private

    def own_notifications
      Alerting::Notification.where(account_id: Current.account.id,
                                   organization_id: Current.organization.id, via: :in_app)
    end

    # Anti-BOLA: solo notifiche proprie (un id altrui → RecordNotFound → 404).
    def set_notification
      @notification = own_notifications.find(params[:id])
    end
    # Le mie notifiche già tagliate per tipo e progetto (la natura resta fuori: le schede devono
    # contarsi a vicenda sullo stesso taglio).
    def filtered_notifications
      scope = own_notifications
      scope = scope.where(event_type: event_filter) if event_filter.any?
      scope = scope.where(project_id: project_filter) if project_filter.any?
      # CYRA-813 — il taglio per macchina sta QUI, dentro il taglio comune, così i chip, le schede per
      # natura e l'elenco raccontano lo stesso insieme (stessa regola di CYRA-315: nessun numero in
      # pagina contraddice l'altro).
      scope = scope.where(subject_type: HOST_SUBJECT_TYPE, subject_id: host_filter_id) if host_filter_id
      scope
    end

    # CYRA-813 — gli avvisi di una macchina si riconoscono dal SOGGETTO della notifica, non dal
    # progetto: i server_* nascono org-scoped con project nil, e due macchine possono condividere un
    # progetto — filtrare per progetto lasciava dentro gli avvisi delle altre. Indice già presente
    # (index_alerting_notifications_on_subject).
    HOST_SUBJECT_TYPE = "Servers::Host"
    UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    # FILTRARE non pretende il permesso della flotta: taglia la PROPRIA casella, quindi restringe
    # soltanto — un id inventato lascia una casella vuota, mai una riga altrui. Nessun lookup qui: un
    # id che non esiste e uno che esiste ma non ha mai fatto scattare niente danno lo stesso vuoto.
    def host_filter_id
      return @host_filter_id if defined?(@host_filter_id)

      id = params[:host_id].to_s
      @host_filter_id = id.match?(UUID_FORMAT) ? id : nil
    end

    # LEGGERE IL NOME sì: è un dato della flotta, e mostrarlo a chi non ha servers.view direbbe, a un
    # id tirato a indovinare, che quella macchina esiste e come si chiama — anche a casella vuota, dove
    # nessun avviso lo avrebbe mai scritto. Quindi il nome passa da visible.servers (org-scoped
    # E a permesso): senza, il taglio resta, l'etichetta no. Un id di un'altra organizzazione non fa
    # comparire un'etichetta falsa, stessa regola del filtro per codice di registrazione della flotta.
    def filtered_host
      return @filtered_host if defined?(@filtered_host)

      @filtered_host = host_filter_id ? visible.servers.find_by(id: host_filter_id) : nil
    end

    def scope_by_nature = filtered_notifications.where(event_type: nature_event_types)

    def unread_count_for(scope) = scope.unread.count

    # Vocabolari chiusi: un valore inventato nella query string vale come nessun filtro, mai come
    # elenco vuoto (stessa regola degli altri elenchi). CYRA-315 — il vocabolario è il catalogo
    # completo e il filtro guarda la colonna della NOTIFICA: prima passava dalla regola che l'aveva
    # prodotta, e commenti e menzioni — che regola non hanno — non erano filtrabili affatto, quindi
    # il link della Home non poteva puntare alle sole conversazioni.
    def event_filter = filter_ids(:event_type) & ::Notifications::Catalog.event_types

    def project_filter = filter_ids(:project_id)

    # CYRA-488 — gli event_type della natura scelta (systems/tickets/agents); [] se assente o ignota.
    def nature_event_types = @nature_event_types ||= ::Notifications::Catalog.nature_event_types(params[:nature])

    # CYRA-488 — non lette raggruppate per natura. Una query (group by event_type), poi ricondotte alla
    # natura. Hash con default 0: le schede senza non lette mostrano semplicemente nessun badge.
    # CYRA-315 — contate sullo stesso taglio del chip (tipo/progetto), altrimenti una scheda
    # dichiarerebbe un numero che l'elenco sotto non ha.
    def nature_unread_counts
      filtered_notifications.unread.group(:event_type).count.each_with_object(Hash.new(0)) do |(event_type, count), acc|
        nature = ::Notifications::Catalog.nature_for(event_type)
        acc[nature] += count if nature
      end
    end
  end
end
