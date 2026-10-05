# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-739 — la vista LISTA («list view»): la tabella filtrabile, ordinabile e paginata che si
    # apre dal bottone della bacheca. È l'unica delle tre pagine con l'ordinamento per colonna e con
    # il selettore fra ricerca per significato e parole esatte.
    module Listing
      extend ActiveSupport::Concern

      include Member::Tickets::Scoping

      # Whitelist ordinamento colonne della lista (contratto Sortable#sorted). Priority e
      # status ordinano per `position` (l'ordine di dominio dell'org, come nei picker),
      # non alfabetico; code per `number` (la sequenza ticket).
      SORT_COLUMNS = {
        "code" => :number,
        "title" => "LOWER(ticketing_tickets.title)",
        "kind" => :kind,
        "project" => { expr: "LOWER(projects.name)", joins: :project },
        "priority" => { expr: "types_ticket_priorities.position", joins: :priority },
        "status" => { expr: "types_ticket_statuses.position", joins: :status },
        "created" => :created_at,
        "due" => :due_at,
        "assignee" => { expr: "LOWER(accounts.name)", joins: :assignee }
      }.freeze

      included do
        # CYRA-694 — l'elenco ricorda i propri filtri: qui, a differenza delle board, ci sono anche
        # lo stato (non è un asse) e l'ordinamento scelto.
        remembers_filters :kind, :status_id, :priority_id, :assignee_id, :reviewer_id, :project_id,
                          :group_id, :agent_eligibility, :awaiting, :questions, :unassigned, :overdue, :workflow, :q, :semantic, :sort, only: :list
      end

      # Tabella filtrabile/ordinabile/paginata ("list view"), raggiunta dal bottone nella board.
      def list
        # Filtri (senza ricerca né sort) = base dei CHIP: la ricerca riduce solo le righe, i chip dicono
        # quanti ticket esistono davvero (CYRA-387). Niente sort qui: un JOIN di ordinamento su una
        # colonna nullable (assignee) escluderebbe righe e falserebbe il COUNT.
        filtered = apply_ticket_filters(visible.tickets)
        scope = searched(sorted(list_display_scope(filtered), columns: SORT_COLUMNS))
        @pagination = paginate(scope)
        @tickets = @pagination.records
        # Chip header: totale reale (non il conteggio filtrato/cercato di prima, CYRA-1→CYRA-387) +
        # quelli in stato "in corso" + quelli ancora da valutare (gate agenti CYRA-184), tutti sul
        # filtrato non cercato. Il "N risultati" della toolbar resta @pagination.total (i risultati).
        # CYRA-408 — scadenza e assegnatario spariscono dalla tabella quando NESSUNO dei risultati
        # mostrati le ha: erano due colonne di trattini su ogni riga, e lo spazio serviva al titolo.
        # Solo sulla pagina corrente: la tabella dichiara sotto cosa ha nascosto.
        @show_due = @tickets.any?(&:due_at)
        @show_assignee = @tickets.any?(&:assignee_id)
        # CYRA-623 — lo stesso segno «bloccato» che la bacheca mostra già: stessa fonte, stessa query
        # aggregata per l'intera pagina. In elenco «bloccato» è già il nome di un filtro che riguarda
        # un'altra cosa (il permesso di lavorazione automatica), quindi il segno va sulla RIGA.
        @blocked_ticket_ids = blocked_ticket_ids(@tickets)
        # CYRA-844 — l'etichetta «N domande aperte» sulla riga (una query per pagina) e il contatore
        # in testa, fuori da filtri e ricerca come «Aspettano te».
        @open_questions_counts = open_questions_among(@tickets)
        @open_questions_count = open_questions_count
        @tickets_total = filtered.count
        @list_in_progress = filtered.where(status_id: in_progress_status_ids).count
        @list_pending_eligibility = filtered.agent_eligibility_pending.count
        @awaiting_count = awaiting_review_count
        @in_progress_labels = in_progress_status_labels
        @saved_views = saved_views_for("tickets")
        # CYRA-395 — a chi non ha ancora nessuna vista ne offriamo due già pronte: una funzione che
        # serve a domare mille ticket non può chiedere di immaginarsela da zero. Sono filtri in un
        # link, non righe salvate: nessuno si ritrova in casa roba che non ha creato.
        @saved_view_presets = @saved_views.any? ? [] : ticket_view_presets
        # Empty state: distingue "nessun risultato" (ricerca/filtro attivi → cita e azzera) da
        # "nessun ticket" (davvero vuoto → crea il primo).
        @search_query = search_q
        @search_active = ticket_search_active?
        # Modalità dichiarata sopra i risultati (CYRA-553): true = per significato (predefinita),
        # false = parole esatte. Stessa regola di searched() e del selettore nella barra.
        @semantic_mode = semantic_search?
      end

      private

      # Scope di DISPLAY della list (righe della tabella): i preload per il rendering + l'ordinamento
      # base, applicati allo scope GIÀ filtrato. Il #list gli accoda sorted+searched — sorted PRIMA di
      # searched: con semantic=1 il reorder(nil).in_order_of della ricerca semantica sovrascrive
      # l'ordinamento colonna, la pertinenza vince per design. Separato dai conteggi header, che vivono
      # sullo scope filtrato puro (CYRA-387): la ricerca non deve azzerare i chip.
      def list_display_scope(filtered)
        filtered.with_attached_files
                .includes(:project, :status, :priority, :assignee, agent_lease: %i[account host])
                .order(created_at: :desc)
      end

      # I due tagli che rispondono alle domande di sempre: «cosa aspetta me» e «cosa scotta».
      def ticket_view_presets
        high_priority = Current.organization.ticket_priorities.active.find_by(code: "high")
        open_records = Current.organization.ticket_statuses.active.reject { |status| status.category_done? }
        presets = [ { key: "mine", name: t("shared.saved_views.preset_mine"),
                      filters: { "assignee_id" => [ Current.account.id ] } } ]
        if high_priority && open_records.any?
          presets << { key: "high_open", name: t("shared.saved_views.preset_high_open"),
                       filters: { "priority_id" => [ high_priority.id ], "status_id" => open_records.map(&:id) } }
        end
        presets
      end
    end
  end
end
