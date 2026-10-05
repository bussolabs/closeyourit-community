module Member
  # Guide help in-app (Errors, Uptime, Performance): pagine statiche read-only che spiegano come
  # collegare la propria app. Nessun model, nessuna guard di ruolo: accessibili a chiunque abbia
  # un'organizzazione di contesto (member/customer/admin/owner), come ogni controller dell'area member.
  class GuidesController < Member::BaseController
    permission_not_required "Guide che spiegano come si collega e si usa il prodotto: testo uguale " \
                            "per tutti, nessun dato dell'organizzazione."

    def index; end

    # CYRA-435 — le due guide d'insieme: non spiegano una funzione, spiegano il prodotto. Non sono
    # raggiungibili da una pagina (Guides::Map le tiene in STANDALONE), ma dall'indice, che è dove
    # guarda chi arriva il primo giorno.
    def overview; end

    # CYRA-631 — gli stati che la guida elenca sono quelli DELL'ORGANIZZAZIONE che sta leggendo, non
    # un elenco scritto a mano: prima ne raccontava quattro mentre quelli installati sono cinque, e
    # uno stato aggiunto da un'organizzazione non sarebbe comparso mai. Stesso ordine e stessa parola
    # della bacheca.
    def ticket_lifecycle
      @states = ::Types::TicketStatus.active.ordered.where(organization: current_organization)
    end

    # CYRA-397 — la guida valeva per un solo linguaggio, mentre l'ingest riceve già da JS e Flutter:
    # chi non usa Ruby non aveva nessuna strada d'ingresso. Il kit scelto arriva da `?sdk=`, reso
    # lato server come le schede del ticket: indirizzo condivisibile e nessun JS necessario.
    # Whitelist anti-tamper: un valore ignoto torna al primo, non rende una pagina vuota.
    SDKS = %w[ruby js dart].freeze

    def errors
      @sdk = SDKS.include?(params[:sdk]) ? params[:sdk] : SDKS.first
    end

    def uptime; end

    def questions; end

    # CYRA-940 — what a visitor's request is, how a project opts in and what is kept about the writer.
    def helpdesk; end

    # What the assistant answers, what it prepares for you to confirm, what it never does.
    def assistant; end

    # CYRA-745 — «chi ha fatto cosa e quando»: cosa unisce il registro, e cosa resta fuori di
    # proposito (la cassaforte personale di ciascuno, che nessun amministratore deve poter leggere).
    def activity; end

    def performance; end

    def logs; end

    def traces; end

    def measurements; end

    def session_health; end

    # CYRA-376 — le sessioni registrate erano la funzione più vendibile e la meno spiegata: nessuna
    # guida la nominava, e la pagina non diceva come accenderla.
    #
    # CYRA-648 — poi la guida prometteva che bastasse l'interruttore, «senza toccare il codice»: è
    # falso, e il modo in cui è falso non lascia tracce. L'interruttore apre il canale lato server
    # (Api::V1::ReplaysController), ma il sito non manda niente finché non chiede il replay nel
    # codice di avvio E non carica la libreria che lo registra — che il kit NON porta con sé (resta
    # zero-dipendenze e usa `window.rrweb` se la pagina lo mette a disposizione, altrimenti tace).
    # Quindi qui vale la stessa regola della guida delle statistiche (CYRA-501): il codice si legge
    # già compilato per il progetto scelto, e la chiave pubblica — che è una credenziale di ingest —
    # la vede solo chi gestisce i codici di quel progetto.
    def replays
      # I progetti su cui il replay è possibile: piattaforma web dichiarata. È la stessa condizione
      # con cui l'interruttore compare nelle impostazioni, quindi il passo «accendilo» ha sempre dove
      # atterrare. Il permesso di modificarle si valuta DOPO, sul solo progetto scelto: chi non ce
      # l'ha deve comunque poter leggere il codice da consegnare a chi gestisce il sito.
      @projects = visible.projects.session_replay_capable.order(:name)
      # Progetto esplicito solo se DAVVERO visibile: `find_by` sullo scope (mai `find`), così una
      # sigla di un'altra organizzazione ricade sul primo leggibile invece di far esplodere una
      # pagina di sola lettura.
      @project = @projects.find_by(id: params[:project_id]) || @projects.first
      return if @project.nil?

      @can_edit_project = can?("projects.edit", scope: @project)
      @can_read_tokens = can?("tokens.manage", scope: @project)
      @public_key = @project.tokens.active.order(:created_at).first&.public_key if @can_read_tokens
    end

    # CYRA-485 — i lavori programmati non avevano una guida: la funzione era invisibile a chi
    # non l'aveva già configurata da fuori.
    def crons; end

    def servers; end

    # CYRA-501 — il passo che conta («inserisci il codice nel tuo sito») nominava lo snippet senza
    # mostrarlo, e l'unico bottone portava all'elenco nudo dei progetti. Qui il codice si legge già
    # compilato per il progetto scelto, con la stessa regola della pagina delle statistiche: la
    # chiave pubblica è una credenziale di ingest, quindi la vede solo chi gestisce i codici di quel
    # progetto (`tokens.manage`); a tutti gli altri resta il segnaposto. Senza progetti che
    # raccolgono statistiche la guida resta leggibile con l'esempio: una guida non ha empty state.
    def analytics
      @projects = visible.projects.analytics_collecting.order(:name)
      # Progetto esplicito solo se DAVVERO visibile: `find_by` sullo scope (mai `find`), così una
      # sigla di un'altra organizzazione ricade sul primo leggibile invece di far esplodere una
      # pagina di sola lettura.
      @project = @projects.find_by(id: params[:project_id]) || @projects.first
      return if @project.nil?

      @can_read_tokens = can?("tokens.manage", scope: @project)
      @public_key = @project.tokens.active.order(:created_at).first&.public_key if @can_read_tokens
    end

    # CYRA-501 — come lavorano le macchine: il ciclo di un ticket passaggio per passaggio, cosa
    # significa ogni esito, quando arriva una richiesta di approvazione, cosa succede se non si
    # risponde e cosa comporta revocare la certificazione. Era la funzione da cui dipende il valore
    # del prodotto, ed era l'unica senza una guida.
    def agents; end

    # CYRA-593 — l'elenco di tutte le lavorazioni in volo: cosa ci si trova dentro (anche ciò che non
    # chiede niente a nessuno), i tre stati, e perché l'azione compare solo su alcune righe.
    # CYRA-501 — la versione delle competenze: cosa significa fissarla, chi la aggiorna da solo e
    # cosa vuol dire riportare le macchine a una versione più vecchia.
    def skill_bundles; end

    def secrets; end

    # CYRA-79 — il valore assegnato a UNA persona: quando serve, chi può darlo, e le tre cose che non
    # fa (non lo cambia chi lo riceve, non si vede in lista, non esce mai verso GitHub).
    def secret_overrides; end

    # CYRA-777 — «valore in comune»: il prodotto guarda i VALORI e si accorge che lo stesso è
    # ripetuto in più progetti. È la parte meno intuitiva del vault (nessuno si aspetta che un
    # sistema riconosca due segreti uguali senza vederli), e quello che NON fa — non sposta mai
    # niente da solo, non cambia il nome che ogni progetto usa — va detto quanto quello che fa.
    def shared_values; end

    # CYRA-160 — il riepilogo periodico dei dati via email: quando arriva, cosa contiene, e perché
    # non è la stessa cosa degli avvisi (che raccontano un fatto appena successo).
    def reports; end

    def knowledge; end

    def knowledge_review; end

    def tickets; end

    def vault; end

    def feature_matrix; end

    def vulnerabilities; end

    def seo; end

    def approvals; end

    def guidance; end

    # CYRA-439 — chi può fare cosa: ruoli, permessi, perimetro e i permessi delicati.
    def permissions; end

    # CYRA-441 — dove vivono le cose: organizzazione, gruppi, progetti, ambienti, piattaforme. Sono i
    # contenitori che ogni altra pagina dà per noti, e nessuna spiegava; si incrociano anche fra loro
    # (un controllo di raggiungibilità vuole una piattaforma che lo sostenga E un ambiente dichiarato),
    # e quell'incrocio si scopriva solo sbattendoci contro.
    def structure; end

    # CYRA-454 — la sezione Dataset era vuota da mesi e nessuna guida la nominava: qui si spiega
    # quando conviene insegnare una scelta ripetitiva, come si fa e cosa la funzione NON è (non ha
    # nessun legame con le macchine che lavorano i ticket).
    def datasets; end

    # CYRA-545 — i servizi esterni collegati con la chiave dell'organizzazione: cos'è una chiave,
    # dove si prende, perché non si rilegge più dopo averla incollata e cosa si spegne togliendola.
    # Sono le quattro domande che la pagina non può spiegare per esteso senza diventare prosa.
    def integrations; end

    # CYRA-879 — moving a project or group to another organization: who can, the blockers and what
    # detaches. The move page links here.
    def project_moves; end
  end
end
