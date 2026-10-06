# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-739 — the ticket board (all tickets, columns = statuses): a card block per column with a
    # «show more» footer, a recent window on done statuses, done columns collapsed by default, and
    # aggregate counts that stay the true total. The columns are built by Ticketing::BoardScope.
    module Boards
      extend ActiveSupport::Concern

      include Member::Tickets::Scoping

      included do
        # Opzioni leggere per i select filtro delle board: solo progetti/priorità/assegnatari, senza
        # il carico delle opzioni del modulo (piattaforme e mappa milestone non servono qui).
        before_action :load_board_filters, only: :index

        # CYRA-694 — the board remembers its filters (per-path memory).
        # Qui manca status_id: è l'asse delle colonne.
        remembers_filters :kind, :project_id, :group_id, :priority_id, :assignee_id, :reviewer_id,
                          :agent_eligibility, :awaiting, :questions, :q, :semantic, only: :index

        # Path del «mostra altre» reso nei footer di colonna (CYRA-390): la view lo chiama per
        # costruire il link Turbo Stream con i filtri correnti al seguito.
        helper_method :board_more_path
      end

      # Kanban board = vista di DEFAULT: colonne = status attivi ordinati, card = ticket dell'org
      # raggruppati per status. La tabella vive sulla pagina separata #list ("list view").
      def index
        statuses = Current.organization.ticket_statuses.active.ordered.to_a
        # Filtri board (stesse chiavi param della list, senza status che è l'asse colonne) come base
        # condivisa: le CARD si riducono anche per la ricerca (searched sotto), i CHIP no (CYRA-387).
        # agent_lease col suo titolare: la card mostra chi sta lavorando il ticket, e senza il preload
        # nidificato ogni card farebbe due query in più (lease + account/host).
        filtered = apply_ticket_filters(visible.tickets)
        scope = searched(filtered.with_attached_files
          .includes(:project, :priority, :assignee, :status, agent_lease: %i[account host]))
        # Conteggi header (chip): totale ticket sulla board + quelli in stato "in corso". Contati sullo
        # scope FILTRATO ma NON cercato (CYRA-387): una ricerca senza risultati non deve dire "0 ticket"
        # a chi ne ha. Ristretti agli status attivi = le colonne mostrate, così il chip non conta ticket
        # in stati archiviati che nessuna colonna espone. Una sola query aggregata (group by status).
        # È ANCHE il totale reale di ogni colonna (CYRA-390): il chip di colonna non mente mai, nemmeno
        # quando le card mostrate sono una finestra recente o un primo blocco paginato.
        counts = filtered.where(status_id: statuses.map(&:id)).group(:status_id).count
        # Ogni colonna carica solo il primo blocco, e le colonne CONCLUSE lo restringono alla finestra
        # recente (Ticketing::BoardScope). Query per colonna, con LIMIT, invece dell'unica query che
        # caricava tutte le 1163 righe (di cui 931 concluse) e le riversava in pagina.
        @columns = Ticketing::BoardScope.columns(scope: scope, statuses: statuses, counts: counts, searching: search_q.present?)
        # Preferenza personale delle colonne ridotte (CYRA-390): la view rende collassato ciò che sta
        # nel Set già dal server, senza flash e senza JS obbligatorio. Di default (board mai
        # configurata) si riducono le sole colonne CONCLUSE vuote nella finestra recente (CYRA-691).
        @collapsed_status_codes = board_collapsed_codes(statuses)
        # Badge "bloccato" (CYRA-82): id dei ticket con almeno un prerequisito aperto, in UNA sola query
        # aggregata sulle sole card mostrate — mai `blocked?` per card (sarebbe N+1). La card consulta il Set.
        @blocked_ticket_ids = blocked_ticket_ids(@columns.flat_map(&:tickets))
        # Badge «Aspetta te» sulle card (CYRA-374): dai ticket già in memoria, col loro status
        # precaricato — nessuna query in più. Un Set perché il partial è reso anche dai broadcast, dove
        # Current non esiste: la card riceve un booleano, non va a chiederselo.
        @awaiting_ticket_ids = awaiting_ids_among(@columns.flat_map(&:tickets))
        # CYRA-844 — «N domande aperte» sulle card (una query per bacheca) e il contatore in testa.
        @open_questions_counts = open_questions_among(@columns.flat_map(&:tickets))
        @open_questions_count = open_questions_count
        @board_total = counts.values.sum
        # CYRA-555 — con una ricerca attiva le colonne vuote non sono vuote: non hanno corrispondenze.
        # Il chip di colonna resta il totale reale (counts, non cercato), quindi senza questa distinzione
        # una colonna dichiarava centotrentuno ticket e sotto scriveva «Niente qui».
        @search_active = ticket_search_active?
        # K11/K12 — while a search is on each column reads "found / total", and a column without a
        # match collapses by itself (never saved as the person's choice).
        @found_counts = (scope.unscope(:order).where(status_id: statuses.map(&:id)).group(:status_id).count if search_q.present?)
        @auto_collapsed_ids = @found_counts ? statuses.map(&:id).reject { |id| @found_counts[id].to_i.positive? }.to_set : Set.new
        # A column holding a match opens even if the person collapsed it; the saved choice is untouched.
        @collapsed_status_codes -= statuses.reject { |status| @auto_collapsed_ids.include?(status.id) }.map(&:code) if @found_counts
        @board_in_progress = statuses.sum { |status| status.category_in_progress? ? counts[status.id].to_i : 0 }
        @awaiting_count = awaiting_review_count
        @in_progress_labels = in_progress_status_labels
      end

      # «Mostra altre» di una colonna (CYRA-390): append incrementale via Turbo Stream. La pagina 1 è il
      # primo blocco già reso nell'index, quindi il footer chiede dalla 2 in poi. Stessa finestra e stesso
      # ordinamento dell'index (Ticketing::BoardScope) più i filtri correnti portati dalla querystring del
      # link. Senza Turbo (HTML) ripiega sulla vista lista filtrata per stato: le altre card restano
      # raggiungibili anche a JS spento, ed è lì che si consulta lo storico oltre la finestra recente.
      def column
        @status = Current.organization.ticket_statuses.active.find(params[:status_id])
        page = [ params[:page].to_i, 2 ].max
        base = apply_ticket_filters(visible.tickets).with_attached_files
          .includes(:project, :priority, :assignee, :status, agent_lease: %i[account host])
        batch = Ticketing::BoardScope.cards(scope: searched(base), status: @status, page: page,
                                                searching: search_q.present?)
        @cards = batch.tickets
        @has_more = batch.has_more
        @next_page = page + 1
        @can_manage = can_any?("tickets.edit")
        @blocked_ticket_ids = blocked_ticket_ids(@cards)
        @awaiting_ticket_ids = awaiting_ids_among(@cards)
        @open_questions_counts = open_questions_among(@cards)
        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to list_member_tickets_path(status_id: [ @status.id ]) }
        end
      end

      private

      # Opzioni dei select filtro sulla board: il sottoinsieme leggero delle opzioni
      # del modulo — la board filtra per progetto/priorità/assegnatario e non ha un form da riempire.
      def load_board_filters
        filters = Ticketing::FormOptions.board_filters(organization: Current.organization,
                                                       projects: visible.projects)
        @projects = filters.projects
        @priorities = filters.priorities
        @assignees = @reviewers = filters.assignees
      end

      # Codici delle colonne rese ridotte (CYRA-390). Finché l'utente non ha mai configurato la board le
      # colonne CONCLUSE partono ridotte (stanno tutte su 13" senza scorrere); dal primo tocco vale la
      # lista esplicita salvata su Accounts::Account (fonte unica col controller collapse, che al primo
      # tocco materializza lo stesso default prima di applicare il toggle).
      # La preferenza esplicita vince sempre; senza, il default vive in Ticketing::BoardDefaults
      # (CYRA-691): concluse ripiegate solo se vuote nella finestra recente, calcolato sui ticket
      # visibili SENZA filtri né ricerca — la stessa base della materializzazione al primo tocco.
      def board_collapsed_codes(statuses)
        account = Current.account
        return account.board_collapsed_statuses.to_set if account.board_columns_configured?

        Ticketing::BoardDefaults.collapsed_codes(statuses, visible.tickets)
      end

      # Path del «mostra altre» di una colonna (CYRA-390) con i filtri correnti della board al seguito
      # (ricerca, kind/progetto/priorità/assegnatario, gate agenti), più stato e pagina freschi: così il
      # blocco successivo è coerente con ciò che l'utente sta guardando. Solo le chiavi note (whitelist).
      def board_more_path(status, page)
        filters = params.permit(:q, :semantic, :awaiting, :questions, kind: [], project_id: [], group_id: [], priority_id: [],
                                assignee_id: [], reviewer_id: [], agent_eligibility: [])
        column_member_tickets_path(filters.to_h.merge(status_id: status.id, page: page))
      end
    end
  end
end
