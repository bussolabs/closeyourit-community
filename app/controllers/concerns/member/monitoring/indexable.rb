# frozen_string_literal: true

module Member
  module Monitoring
    # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
    #
    # Le diciotto pagine dell'area (errori, log, prestazioni, uptime, disservizi, falle, siti,
    # registrazioni, server, lavori programmati, database…) fanno tutte la stessa cosa: prendono lo
    # scope di ciò che si può vedere, lo restringono al progetto e al termine cercato, lo ordinano e
    # lo paginano. Ognuna se lo era riscritto, e non nello stesso modo: tre grafie diverse per il
    # filtro whitelisted (`filter_ids(:x) & keys`, `Array(params[:x]).map(&:to_s) & keys`,
    # `Array(params[:x]).reject(&:blank?) & keys`) e due per la paginazione. Sfumature diverse sulla
    # stessa cosa non sono varietà: sono il motivo per cui una correzione fatta su una pagina non
    # arriva mai alle altre diciassette. Presidio: `spec/config/monitoring_index_base_spec.rb`.
    #
    # Poggia su Listable (`filter_ids`, `search_q`, `paginate`, `sorted`, `requested_per`), che vive
    # su Member::BaseController e serve TUTTE le liste del prodotto: qui sta solo ciò che è proprio
    # dell'area di controllo. Il concern è inerte finché un controller non ne chiama i metodi.
    module Indexable
      extend ActiveSupport::Concern

      # Il periodo dell'area (CYRA-340) arriva da qui, non più incluso a mano da tre controller su
      # diciotto: gli helper di vista sono disponibili ovunque, mentre i before_action che
      # ripristinano e ricordano la scelta li accende solo chi dichiara `monitoring_time_range`.
      include TimeRangeable

      class_methods do
        # Questo elenco vive dentro il periodo dell'area: lo ripristina dalla sessione e ricorda la
        # scelta per le pagine successive. Solo sull'elenco, dove il periodo è una SCELTA: nei
        # dettagli `from`/`to` sono il blocco cliccato sull'istogramma, un drill-down locale che non
        # deve diventare il periodo di tutta l'area.
        def monitoring_time_range(only: :index)
          before_action :restore_time_range, :remember_time_range, only: only
        end
      end

      private

      # Un filtro multi ristretto ai valori che il dominio riconosce davvero: quello che arriva
      # dall'indirizzo è una richiesta, non un permesso di scrivere nel WHERE. `allowed` sono le
      # chiavi di un enum o una lista di costanti; il confronto è per stringa, così i simboli
      # dichiarati nel dominio funzionano come le stringhe che arrivano dal browser.
      def enum_filter(key, allowed) = filter_ids(key) & Array(allowed).map(&:to_s)

      # «Guarda solo questo progetto»: la domanda che ogni pagina dell'area sa fare. `column` esiste
      # per gli elenchi che al progetto si legano da un'altra parte (gli incident passano dai
      # monitor, i rilievi SEO dal sito).
      def filter_by_project(scope, column: :project_id)
        ids = filter_ids(:project_id)
        ids.any? ? scope.where(column => ids) : scope
      end

      # La ricerca a testo libero della toolbar, su una o più colonne qualificate ("tabella.colonna").
      #   exact:  una colonna in più confrontata per intero, non a pezzi — incollare un codice di
      #           richiesta copiato da un errore deve trovare QUELLA richiesta, non i messaggi che la
      #           nominano.
      #   joins:  la tabella si aggiunge SOLO quando c'è davvero un termine da cercare, mai a vuoto.
      def filter_by_search(scope, *columns, exact: nil, joins: nil)
        return scope if search_q.blank?

        scope = scope.joins(joins) if joins
        scope.where(search_condition(*columns, exact: exact))
      end

      # I nomi di colonna diventano nodi Arel, non pezzi di stringa SQL: il termine cercato è sempre
      # un valore quotato e non può mai diventare istruzione.
      def search_condition(*columns, exact: nil)
        pattern = "%#{search_q}%"
        condition = columns.map { |column| search_column(column).matches(pattern) }.reduce(:or)
        exact ? condition.or(search_column(exact).eq(search_q)) : condition
      end

      def search_column(qualified)
        table, column = qualified.to_s.split(".")
        Arel::Table.new(table)[column]
      end

      # L'elenco della pagina: ordinato con la whitelist del controller (`columns:`, contratto
      # Sortable#sorted — senza, l'ordine di default dello scope resta), paginato, e il riepilogo per
      # il pager lasciato in `@pagination`. Restituisce le righe da assegnare alla vista.
      def paginated(scope, columns: nil, per: Pagination::DEFAULT_PER)
        scope = sorted(scope, columns: columns) if columns
        @pagination = paginate(scope, per: per)
        @pagination.records
      end

      # Lo stesso, per righe GIÀ in memoria (l'inventario dei database è costruito da un query
      # object, non è una relation): il pager non distingue le due sorgenti, e nemmeno la scelta di
      # quante righe per pagina — che prima su quelle due pagine c'era nella toolbar e non faceva
      # niente.
      def paginated_rows(rows, per: Pagination::DEFAULT_PER)
        @pagination = Pagination.from_array(rows, page: params[:page], per: requested_per(per))
        @pagination.records
      end

      # La tendina «Progetto» dei filtri. Lo scope si passa quando la pagina ne vuole uno più
      # stretto (solo i progetti che raccolgono statistiche, solo quelli con una piattaforma web).
      def load_filter_projects(scope = nil)
        @projects = (scope || visible.projects).order(:name)
      end

      # CYRA-822 — i progetti a cui questa pagina si iscrive per ricevere gli aggiornamenti in
      # arrivo. Vuoto significa «il segnale unico dell'organizzazione», che è anche il caso normale:
      # senza filtro la pagina mostra tutti i progetti visibili e ogni evento la riguarda davvero.
      #
      # I progetti si prendono dall'elenco della tendina, cioè da ciò che si VEDE, non da ciò che
      # arriva nell'indirizzo: il segnale non porta contenuti, ma dire «in questo progetto è appena
      # successo qualcosa» è già un'informazione, e non deve poterla ottenere chi il progetto non lo
      # vede. Il confronto avviene in memoria sull'elenco già caricato — nessuna query in più, e
      # nessun identificativo inventato che arrivi fino al database.
      #
      # Sopra il tetto (`::Monitoring::Constants::LIST_STREAM_PROJECT_CAP`) si torna al segnale unico:
      # una sottoscrizione per progetto è una connessione per sessione, e chi ne seleziona molti
      # riceverebbe comunque quasi tutti i segnali. Va chiamato DOPO `load_filter_projects`.
      def live_stream_projects
        wanted = filter_ids(:project_id)
        return [] if wanted.empty?

        chosen = Array(@projects).select { |project| wanted.include?(project.id.to_s) }
        chosen.size > ::Monitoring::Constants::LIST_STREAM_PROJECT_CAP ? [] : chosen
      end

      # Elenco vuoto: «non è ancora arrivato niente» o «i filtri non lasciano passare nulla»? Sono
      # due frasi diverse, e la seconda ha una via d'uscita. Una query solo quando serve davvero.
      def records_present?(records, visible) = records.any? || visible.exists?

      # CYRA-821 — il turbo-frame in cui vivono i risultati di questa pagina. `nil` = la pagina non
      # ne ha uno, e allora nessuna richiesta è «del frame dei risultati».
      def results_frame_id = nil

      # Solo il frame DEI RISULTATI, mai un frame qualunque: una richiesta che arriva da un altro
      # frame (una ricerca, un'anteprima) deve ricevere la pagina intera, dove il frame che sta
      # cercando c'è davvero. Rispondere coi soli risultati gli toglierebbe proprio quel nodo.
      def results_frame_request? = results_frame_id.present? && turbo_frame_request_id == results_frame_id

      # La risposta al frame è SOLO il frame. Non è la stessa cosa che togliere il layout: rendere
      # la pagina intera senza intestazione farebbe comunque partire le query di tutto ciò che il
      # browser poi butterebbe via — chip, grafici, facet, viste salvate. Qui si rende il solo
      # frammento, quindi quel lavoro non si fa proprio.
      def render_results_frame = render(partial: "results", layout: false)
    end
  end
end
