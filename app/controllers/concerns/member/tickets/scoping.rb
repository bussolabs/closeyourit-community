# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-739 — il PERIMETRO delle pagine-elenco dei ticket: quali ticket entrano (filtri della
    # toolbar, ricerca, «aspettano me») e i numeri che le testate dichiarano. Bacheca ed elenco
    # fanno la stessa domanda e devono farla nello stesso modo: un filtro che vale
    # su una pagina e non sull'altra è il modo in cui due elenchi della stessa cosa iniziano a
    # rispondere numeri diversi.
    module Scoping
      extend ActiveSupport::Concern

      included do
        # CYRA-374 — `awaiting_filter?` dice alle testate se il contatore «Aspettano te» è quello
        # acceso: da lì dipende se la pill è marcata come filtro attivo e se il click lo accende o
        # lo spegne.
        helper_method :awaiting_filter?
        # CYRA-844 — stessa ragione per il contatore «Domande aperte».
        helper_method :open_questions_filter?
        # CYRA-866 — i Gruppi che il filtro offre, per le tre barre.
        helper_method :ticket_filter_groups
      end

      private

      # Filtri multi (param array) condivisi dalle pagine-elenco (#list, #index).
      # Ogni where scatta solo se il param è presente: la board non espone il chip status e
      # semplicemente non invia quel param → il where corrispondente è saltato.
      def apply_ticket_filters(scope)
        if %w[active blocked].include?(params[:workflow])
          workflows = ::Agents::Workflow.where(completed_at: nil, cancelled_at: nil)
          workflows = workflows.where.not(blocked_at: nil) if params[:workflow] == "blocked"
          scope = scope.where(id: workflows.select(:ticket_id))
        end
        scope = scope.where(assignee_id: nil) if params[:unassigned] == "1"
        scope = scope.where(due_at: ...Time.current) if params[:overdue] == "1"
        scope = scope.where(kind: filter_ids(:kind)) if filter_ids(:kind).any?
        scope = scope.where(status_id: filter_ids(:status_id)) if filter_ids(:status_id).any?
        scope = scope.where(priority_id: filter_ids(:priority_id)) if filter_ids(:priority_id).any?
        scope = scope.where(assignee_id: filter_ids(:assignee_id)) if filter_ids(:assignee_id).any?
        # CYRA-374 — chi deve revisionare, accanto a chi ci lavora: il campo era su ogni ticket ma non
        # esisteva un modo di chiedere "fammi vedere quelli di Anna".
        scope = scope.where(reviewer_id: filter_ids(:reviewer_id)) if filter_ids(:reviewer_id).any?
        scope = scope.where(project_id: filter_ids(:project_id)) if filter_ids(:project_id).any?
        # CYRA-866 — un Gruppo vale tutti i suoi progetti. Lo scope è già quello dei ticket visibili.
        scope = scope.where(project_id: Projects::Project.where(group_id: filter_ids(:group_id)).select(:id)) if filter_ids(:group_id).any?
        # Gate agenti (CYRA-184): filter_ids ritorna stringhe, che Rails risolve sull'enum.
        if filter_ids(:agent_eligibility).any?
          scope = scope.where(agent_eligibility: filter_ids(:agent_eligibility))
        end
        # CYRA-374 — «aspettano me»: subquery sulla scope di dominio invece della condizione riscritta
        # qui, così il taglio dell'elenco e il numero del contatore restano la stessa cosa. Subquery e
        # non `merge`: la scope porta con sé il join sugli status e un `none` (nessun account) va
        # propagato, e nessuna delle due cose sopravvive a un merge.
        scope = scope.where(id: awaiting_review_scope.select(:id)) if awaiting_filter?
        # CYRA-844 — «con domande aperte»: la definizione di «aperta» è quella del modello
        # (Ticketing::Question.open), non una condizione riscritta qui, così etichetta, contatore e
        # filtro dicono la stessa cosa.
        scope = scope.where(id: open_questions_ticket_ids) if open_questions_filter?
        scope
      end

      # I Gruppi con almeno un progetto visibile: gli altri non porterebbero nessun ticket (CYRA-866).
      def ticket_filter_groups
        @ticket_filter_groups ||= Current.organization.groups
                                         .where(id: visible.projects.select(:group_id)).order(:name).to_a
      end

      # Il contatore «Domande aperte» è acceso? Solo `open` è un valore, per la stessa ragione di
      # `awaiting_filter?`: una query string inventata non deve svuotare un elenco di sola lettura.
      def open_questions_filter? = params[:questions].to_s == "open"

      # Le domande che chi guarda può leggere (CYRA-848): al cliente restano le sole condivise, e i
      # contatori di questa pagina non raccontano che esiste qualcosa che non può vedere.
      def readable_questions
        Ticketing::Question.readable_by(Current.account, organization: Current.organization)
      end

      # Gli id dei ticket con almeno una domanda senza risposta e non ritirata.
      def open_questions_ticket_ids = readable_questions.open.select(:ticket_id)

      # Il numero del contatore: i ticket che vedo con domande aperte, FUORI da filtri e ricerca, come
      # il gemello «Aspettano te» — cliccarlo deve aprire un elenco lungo quanto il numero letto.
      def open_questions_count = visible.tickets.where(id: open_questions_ticket_ids).count

      # ticket_id → numero di domande aperte, fra i ticket già in memoria: UNA query aggregata per
      # l'intera pagina (mai un `questions.open.count` per riga), come per il badge «bloccato».
      def open_questions_among(tickets)
        readable_questions.open.where(ticket_id: tickets.map(&:id)).group(:ticket_id).count
      end

      # Il contatore «Aspettano te» è acceso? Solo `me` è un valore: un `?awaiting=` inventato vale come
      # nessun filtro, come per lo stato della coda Approvazioni — una query string sbagliata non deve
      # svuotare un elenco di sola lettura.
      def awaiting_filter? = params[:awaiting].to_s == "me"

      # Le decisioni che aspettano la persona collegata, fra i ticket che vede. Definizione UNICA
      # (Ticketing::Ticket.awaiting_review_by), la stessa della coda delle Approvazioni.
      def awaiting_review_scope = visible.tickets.awaiting_review_by(Current.account)

      # Il numero del contatore. Volutamente FUORI da filtri e ricerca: risponde a «quante decisioni
      # aspettano me», non «quante fra quelle che sto guardando». Se scendesse con un filtro di
      # progetto acceso, cliccarlo aprirebbe un elenco più corto del numero appena letto — ed è anche
      # ciò che lo tiene uguale a quello della pagina Approvazioni, che di filtri della lista non sa
      # niente.
      def awaiting_review_count = awaiting_review_scope.count

      # Gli id (fra i ticket già in memoria) che aspettano una mia decisione: il badge di riga senza
      # una query per card. `status` è precaricato da chi carica le card.
      def awaiting_ids_among(tickets)
        tickets.select { |ticket| ticket.awaiting_review_by?(Current.account) }.map(&:id).to_set
      end

      # ID degli status attivi in categoria "in corso" dell'org (chip in_progress di board e lista).
      # Filtrati per `active` per allinearsi alla board, le cui colonne sono solo gli status attivi.
      def in_progress_status_ids
        Current.organization.ticket_statuses.active.category_in_progress.select(:id)
      end

      # Etichette (localizzate) degli status attivi in categoria "in corso": il chip che li somma le
      # elenca nel tooltip, così "In corso: 86" dichiara di aggregare più stati (In lavorazione + In
      # revisione) invece di nasconderlo (CYRA-392).
      def in_progress_status_labels
        Current.organization.ticket_statuses.active.category_in_progress.ordered.map(&:display_label)
      end

      # Ramo ricerca (CYRA-739 → Ticketing::Search::Query): codice esatto, poi per significato
      # (ordinata per pertinenza) o parole esatte (semantic=0), scelto dall'utente col selettore di
      # modalità come su Idee e Conoscenza (CYRA-553). Servizio embedding giù → fallback parole esatte
      # + hint muto (@semantic_degraded): MAI un errore utente.
      def searched(scope)
        return scope if search_q.blank?

        result = Ticketing::Search::Query.call(scope: scope, query: search_q,
                                               projects: visible.projects,
                                               semantic: semantic_search?)
        @semantic_degraded = true if result.degraded
        result.scope
      end

      # Modalità di ricerca: "0" esplicito = parole esatte; assente o "1" = per significato (default).
      # Unico punto di verità per searched, @semantic_mode (banner) e il selettore nel toolbar.
      #
      # Solo la vista LISTA offre la scelta, perché è lì che vive il selettore: la board
      # continua a cercare per parole esatte. Il default vale per la lista anche quando il param non
      # c'è (un link con ?q= da fuori), altrimenti il selettore direbbe «per significato» mentre il
      # server cerca le parole esatte.
      def semantic_search?
        action_name == "list" && params[:semantic] != "0"
      end

      # La list distingue "nessun risultato per una ricerca/filtro" da "nessun ticket": vero se c'è una
      # ricerca testuale o un filtro toolbar attivo. Nel primo caso l'empty state cita i criteri e offre
      # di azzerarli; nel secondo invita a creare il primo ticket (CYRA-387).
      def ticket_search_active?
        search_q.present? || ticket_filters_present?
      end

      def ticket_filters_present?
        return true if awaiting_filter? || open_questions_filter?

        %i[kind status_id priority_id assignee_id reviewer_id project_id group_id agent_eligibility]
          .any? { |key| filter_ids(key).any? }
      end

      # Set degli id (tra i `tickets` della board) con almeno un prerequisito NON ancora done — il badge
      # "bloccato". UNA query aggregata (mai un `blocked?` per card: così anche una board con centinaia di
      # card resta una query sola). Fonte unica condivisa col serializer CLI: Connections::TicketDependency.
      def blocked_ticket_ids(tickets)
        Connections::TicketDependency.blocked_ids_among(tickets.map(&:id))
      end
    end
  end
end
