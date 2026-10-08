# frozen_string_literal: true

module Member
  module Home
    # La pila delle approvazioni (CYRA-262): la coda intera a sinistra, il testo per esteso al centro,
    # la decisione a destra. La home resta il launcher; qui si lavora — si legge davvero ciò su cui si
    # decide, e dopo ogni decisione si apre da sola la card successiva.
    #
    # Dopo una decisione si fa REDIRECT, non Turbo Stream: l'indirizzo deve cambiare insieme alla
    # pagina (`?item=` è la richiesta aperta, e ricaricare deve riaprire QUELLA), e senza JS la
    # pagina funziona lo stesso. CYRA-825 sposta il confine di ciò che il redirect ridisegna: non
    # più il contorno, ma il solo riquadro operativo (vedi WORK_FRAME).
    class ApprovalsController < Member::BaseController
      permission_not_required "Coda delle approvazioni: il confine è rispondere dei progetti; ogni decisione la " \
                              "autorizza il proprio service."

      # CYRA-592 — quante righe la plancia carica prima di paginarle. Il tetto della coda (PAGE_LIMIT,
      # cento) nasce per una PILA che si smaltisce dall'alto: lì la centounesima riga non la guarda
      # nessuno. Qui invece si legge in verticale su tutti i progetti, e le centodieci righe misurate
      # in produzione non possono diventare cento mentre l'intestazione ne dichiara centodieci.
      BOARD_LIMIT = 500

      # CYRA-630 — il secondo elenco della pagina: «quante vanno avanti da sole senza chiederti
      # niente». `?view=in_flight`, non uno stato: non taglia la coda delle decisioni, è un altro
      # elenco con un'altra query. Il nome vive accanto alla query.
      IN_FLIGHT_VIEW = ::Agents::Workflows::InFlight::VIEW

      # I link vecchi arrivano ancora: `?state=retrying` era l'elenco di ciò che riprovava da solo, ed
      # è dentro al perimetro nuovo. Rimandare vale più di un 404 su una pagina che qualcuno ha messo
      # nei preferiti.
      LEGACY_RETRYING_STATE = "retrying"

      # CYRA-655 — da dove è stata presa la decisione, per sapere dove riportarla. VOCABOLARIO
      # CHIUSO, non un URL: un parametro che accetta un indirizzo è una porta aperta verso fuori,
      # e questa pagina la si raggiunge da un link che chiunque può fabbricare. Fuori vocabolario
      # vale nil, cioè «resta sulla plancia» — il comportamento che c'era prima.
      HOME_RETURN = "home"

      # CYRA-825 — il riquadro che si ridisegna a ogni decisione. Comprende INTESTAZIONE (i conteggi),
      # esito della decisione precedente e corpo: erano proprio i conteggi fuori dal riquadro il
      # motivo per cui questa pagina non ne aveva nessuno, e sostituire la sola riga li avrebbe
      # lasciati fermi. O si aggiornano insieme, o non si aggiorna niente.
      #
      # Fuori restano soltanto barra laterale, menu e notifiche — il contorno, che una decisione non
      # cambia. La richiesta del riquadro si riconosce dall'intestazione che manda Turbo, MAI da un
      # parametro nell'indirizzo: il collegamento che si condivide resta quello della pagina intera.
      WORK_FRAME = "approvals-work"

      # CYRA-1059 — the header counters alone: a row action that runs without reloading refreshes only these.
      COUNTS_FRAME = "approvals-counts"

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :state, :project, :agent_id, only: :index

      def index
        # CYRA-630 — l'elenco separato di ciò che va avanti da solo. Prima era `?state=retrying` e
        # conteneva le sole lavorazioni che riprovavano; adesso comprende tutto ciò che è in volo e
        # non aspetta nessuno — lavoro in corso compreso — ed è quello che diceva la pagina
        # «Lavorazioni», che non esiste più.
        return redirect_to(member_home_approvals_path(view: IN_FLIGHT_VIEW)) if params[:state] == LEGACY_RETRYING_STATE

        # CYRA-665 — per chi non risponde di nessun progetto questa vista NON ESISTE: 404 e mai 403,
        # come per una card che non compete (vedi #show). Confrontare le due risposte non deve dire
        # a nessuno quali lavorazioni stiano girando altrove.
        if in_flight_view?
          raise ActiveRecord::RecordNotFound unless cto?

          @in_flight = in_flight
          return render_work_frame
        end

        # Sulla coda delle decisioni serve il solo NUMERO: costruire le righe per non mostrarle
        # sarebbe tre letture in blocco e cinquecento oggetti buttati via a ogni caricamento.
        @in_flight_total = in_flight_total
        @card = selected_card
        # Senza una richiesta aperta si guarda la plancia; con `?item=` si legge e si decide. Le due
        # rese non convivono di proposito: la pila di sinistra era il terzo elenco della stessa coda.
        @batch = queue(limit: (BOARD_LIMIT unless @card))
        @board = board unless @card
        render_work_frame
      end

      # CYRA-591 — la scheda di UNA lavorazione, su una pagina sua.
      #
      # PERCHÉ una pagina e non il pannello centrale della coda: il piano è un documento da mille o
      # duemila parole (analisi tecnica, scenari, definizione di fatto, note) e in una colonna stretta
      # arrivava già troncato. Qui ha la larghezza che gli serve.
      #
      # 404 e mai 403 su ciò che non mi compete: `Detail` risolve sempre dagli scope visibili, quindi
      # `nil` significa «per me non esiste». Un link condiviso non è una scorciatoia per vedere ciò
      # che non vedrei — stessa regola dell'index.
      def show
        key = "#{params[:kind]}:#{params[:id]}"
        @from_in_flight = in_flight_view?
        @card = ::Home::Approvals::Detail.call(**scope_args, key: key)
        return if @card

        # `Detail` ritorna nil per due motivi diversi, e qui NON si distinguono: è voluto. «L'ha già
        # decisa qualcun altro» — con più persone è la norma, e questo link nasce per essere
        # condiviso — e «non è roba mia» devono rispondere allo stesso modo, altrimenti confrontare
        # le due risposte direbbe quali lavorazioni esistono nelle altre organizzazioni.
        #
        # Si rimanda alla coda CON l'item: da lì `#selected_card` ricalcola `@settled` e la pagina
        # racconta com'è finita, come già fa per un link condiviso (CYRA-325). Il 404 di sistema — in
        # inglese, senza menu — era il modo peggiore di dirlo.
        #
        # Il 404 resta per una FAMIGLIA che non esiste: quello non è l'esito di una decisione, è un
        # indirizzo sbagliato, e non rivela niente su niente.
        raise ActiveRecord::RecordNotFound unless ::Home::Approvals::Detail::KINDS.include?(params[:kind])

        redirect_to member_home_approvals_path(item: key, view: view_param)
      end

      # CYRA-899 — the row preview: the same detail the decision panel shows, alone in its frame.
      def preview
        @card = ::Home::Approvals::Detail.call(**scope_args, key: "#{params[:kind]}:#{params[:id]}")
        raise ActiveRecord::RecordNotFound unless @card

        render layout: false
      end

      def decide
        result = ::Home::Approvals::Decide.call(
          **scope_args, key: params[:item], decision: params[:decision], text: decision_text,
          true_actor: Current.true_account
        )
        # CYRA-655 — anche quando la decisione NON passa si torna da dove si era premuto: scaricare
        # sulla plancia chi ha deciso dalla home è esattamente ciò che questa strada evita, e lo
        # farebbe proprio nel momento peggiore, quello in cui c'è un errore da leggere.
        return redirect_to(decision_failure_path, alert: result.error.message) if result.err?

        # In coda l'esito si vede da sé: la riga sparisce dalla pila e si apre la successiva. Chi
        # decide dalla SCHEDA a tutta pagina invece non vede nessuna pila — viene rimandato qui e,
        # senza una parola, non può sapere se la sua decisione è arrivata. Il messaggio compare solo
        # in quel caso, o in coda diventerebbe rumore a ogni riga smaltita.
        flash[:notice] = t("member.approvals.decided") if params[:from_card].present?
        # CYRA-655 — chi ha deciso dalla home ci torna: lì la successiva la sceglie Home::NextDecision
        # (che salta anche i rimandi), quindi non serve passarle quale card aprire.
        return redirect_to(root_path) if return_to_home?

        redirect_to member_home_approvals_path(item: next_key(params[:item]), state: state, project: project_key, agent_id: agent_id, view: view_param)
      end

      # CYRA-284 — accetta in un colpo le card spuntate nella coda. Si torna alla pagina SENZA `item`:
      # dopo una sforbiciata alla pila indovinare quale card aprire sarebbe un tiro a caso, e la prima
      # rimasta è comunque quella ferma da più tempo.
      def bulk
        result = ::Home::Approvals::BulkApprove.call(**scope_args, keys: params[:keys],
                                                     true_actor: Current.true_account)
        return row_approve_outcome(result) if params[:from_row].present? && request.format.turbo_stream?
        return redirect_to(bulk_return_path, alert: result.error.message) if result.err?

        redirect_to bulk_return_path, **bulk_flash(result.value)
      end

      private

      # CYRA-887 — answers picked among the agent's proposals come first, one line per question
      # position; the free text follows. Nothing picked and no text = blank, and Decide refuses it.
      # CYRA-899 — back to the same board after approving, step filter included.
      def bulk_return_path
        phase = params[:phase].to_s.presence_in(::Home::Approvals::Board::PHASES)
        member_home_approvals_path(state: state, project: project_key, agent_id: agent_id, phase: phase, view: view_param)
      end

      def decision_text
        picked = params.fetch(:answers, {}).to_unsafe_h.slice("1", "2", "3")
        lines = picked.sort.filter_map { |position, answer| "#{position}. #{answer.to_s.strip}" if answer.to_s.strip.present? }
        [ *lines, params[:text].to_s.strip.presence ].compact.join("\n")
      end

      # CYRA-825 — alla richiesta del solo riquadro si rende la STESSA vista senza il layout: il
      # riquadro avvolge già tutto ciò che una decisione cambia, quindi non esiste una seconda
      # versione della pagina da tenere allineata a mano. Quello che si risparmia è HTML — barra
      # laterale, menu, notifiche, presenze — e NON lavoro sul database: coda, plancia e conteggi si
      # costruiscono esattamente come prima, perché sono esattamente ciò che deve tornare aggiornato.
      def render_work_frame
        render layout: false if turbo_frame_request_id.in?([ WORK_FRAME, COUNTS_FRAME ])
      end

      # CYRA-1059 — Approve on a row, run without reloading: the row goes only when its key went through.
      def row_approve_outcome(result)
        if result.err?
          flash.now[:alert] = result.error.message
          return render("member/home/approvals/row_outcome", locals: { keys: [] }, status: :unprocessable_content)
        end

        outcome = result.value
        bulk_flash(outcome).each { |type, message| flash.now[type] = message }
        done = outcome.skipped.zero? && outcome.failed.zero?
        render "member/home/approvals/row_outcome", locals: { keys: (done ? Array(params[:keys]).map(&:to_s).grep(Member::ApprovalsBoardHelper::ROW_KEY) : []) },
                                                    status: (outcome.failed.zero? ? :ok : :unprocessable_content)
      end

      # CYRA-290 — lo stato acceso nella riga dei filtri, validato una volta sola contro il vocabolario
      # della coda: un valore inventato vale come "Tutte" e non deve rientrare negli URL che generiamo.
      # Attraversa le decisioni: chi sta smaltendo i piani uno dopo l'altro non deve riaccenderlo a mano.
      # CYRA-317 — il vocabolario comprende anche `retrying`, che non è un taglio della pila ma
      # l'elenco separato di ciò che riprova da solo: attraversa le decisioni per lo stesso motivo
      # (chi chiude una lavorazione impiantata resta nell'elenco da cui è partito).
      def state = @state ||= params[:state].to_s.presence_in(::Home::Approvals::Queue::FILTERABLE_STATES)

      # Un messaggio solo, che dice tutto quello che è successo: accettate, rimaste in coda perché non
      # accettabili in blocco, andate male. Basta un fallimento perché sia un alert: chi ha appena
      # premuto un pulsante su venti card deve accorgersi che una non è passata.
      def bulk_flash(outcome)
        pieces = [ t("member.approvals.bulk.done", count: outcome.approved) ]
        pieces << t("member.approvals.bulk.skipped", count: outcome.skipped) if outcome.skipped.positive?
        if outcome.failed.positive?
          pieces << t("member.approvals.bulk.failed", count: outcome.failed,
                                                      message: outcome.failures.first.message)
          return { alert: pieces.join(" ") }
        end
        { notice: pieces.join(" ") }
      end

      def in_flight_view? = view_param.present?

      # CYRA-655 — `return_to` è confrontato con l'unico valore ammesso, non interpretato: qualunque
      # altra cosa (un path, un dominio, una stringa a caso) vale come «non tornare in home».
      def return_to_home? = params[:return_to].to_s == HOME_RETURN

      # Dove si finisce quando la decisione è respinta: la home per chi decideva da lì, la plancia
      # coi filtri accesi per tutti gli altri.
      def decision_failure_path
        return root_path if return_to_home?

        member_home_approvals_path(state: state, project: project_key, agent_id: agent_id, view: view_param)
      end

      # CYRA-630 — la vista da cui si è partiti, portata avanti attraverso le decisioni: chi chiude
      # una lavorazione impiantata dall'elenco di ciò che va avanti da solo deve ritrovarsi lì, non
      # nella coda delle decisioni da cui non era arrivato.
      def view_param = @view_param ||= (IN_FLIGHT_VIEW if params[:view] == IN_FLIGHT_VIEW)

      # L'elenco vero, coi suoi filtri: si costruisce solo quando lo si sta guardando.
      def in_flight
        ::Agents::Workflows::InFlight.call(
          organization: current_organization, account: Current.account,
          visible_tickets: visible.tickets, visible_projects: visible.projects,
          autonomous: true,
          page: params[:page] || 1, per: params[:per] || Pagination::DEFAULT_PER,
          state: params[:state], project: project_key, agent: agent_id
        )
      end

      # CYRA-665 — rispondo di almeno un progetto? È la stessa domanda della home, e decide se
      # l'elenco di ciò che va avanti da solo esiste per me. Memoizzata: index e viste la fanno
      # entrambe, e sono la stessa query.
      def cto?
        return @cto if defined?(@cto)

        @cto = ::Agents::Workflows::CtoProjects.any?(
          account: Current.account, organization: current_organization,
          visible_projects: visible.projects
        )
      end

      # Il conteggio accanto alla coda: `nil` per chi non risponde di niente, così la riga non
      # compare invece di dire zero (zero vuol dire «non ce n'è nessuna»).
      def in_flight_total
        return nil unless cto?

        ::Agents::Workflows::InFlight.autonomous_count(
          organization: current_organization, account: Current.account,
          visible_tickets: visible.tickets, visible_projects: visible.projects
        )
      end

      def queue(limit: nil)
        ::Home::Approvals::Queue.call(**scope_args, state: state, project: project_key, agent: agent_id,
                                      limit: limit)
      end

      # CYRA-592 — la plancia: le righe della coda con la matrice delle fasi, raggruppate per progetto
      # e paginate. I gate restano quelli della coda, che gliela passa già fatta.
      def board
        ::Home::Approvals::Board.call(batch: @batch, page: params[:page], phase: params[:phase], sort: params[:sort],
                                      per: params[:per] || Pagination::DEFAULT_PER)
      end

      # CYRA-319 — la sigla del progetto accesa nella riga dei filtri. La validazione contro i progetti
      # che hanno davvero righe in coda vive nella Queue (che li conosce): qui basta portarla avanti
      # attraverso le decisioni, come si fa con lo stato.
      def project_key = @project_key ||= params[:project].to_s.presence

      # CYRA-448 — l'agente acceso, portato avanti come lo stato e il progetto.
      def agent_id = @agent_id ||= params[:agent_id].to_s.presence

      # Nessun `item` in query string → nessuna card: si guarda la plancia (CYRA-592). Prima si apriva
      # d'ufficio la più vecchia, che con una pila accanto era un buon default; con una tabella su cui
      # si sceglie dove guardare, aprire una riga a caso deciderebbe al posto di chi guarda.
      #
      # Con un `item` esplicito la card si risolve SEMPRE dagli scope visibili: quella che non mi
      # compete non esiste — un link condiviso non è una scorciatoia per vedere ciò che non vedrei.
      # CYRA-325 — il link a una richiesta è condivisibile, e con più persone «l'ha già decisa
      # qualcun altro» è la norma: sostituire la pagina col 404 di sistema (in inglese, senza menu)
      # era il modo peggiore di dirlo. La plancia si carica lo stesso e il messaggio racconta com'è
      # finita, come già succede a uno `state=` inventato, che ripiega su «Tutte».
      def selected_card
        key = params[:item].presence
        return nil if key.blank?

        card = ::Home::Approvals::Detail.call(**scope_args, key: key)
        @settled = ::Home::Approvals::Settled.call(**scope_args, key: key) if card.nil?
        card
      end

      # La card successiva da aprire: la prima della coda ricalcolata che non sia quella appena
      # decisa. Di norma la decisa è già uscita dalla pila; resta in coda solo quando ho chiesto
      # precisazioni, e in quel caso è giusto scavalcarla. Col filtro acceso la coda ricalcolata è
      # già quella filtrata (`#queue` lo passa), quindi la successiva è dello stesso stato: è ciò che
      # rende il filtro utile, invece di rispedirti nel mucchio dopo ogni decisione.
      def next_key(decided_key)
        queue.items.find { |item| item.key != decided_key }&.key
      end

      def scope_args
        { account: Current.account, organization: current_organization,
          visible_projects: visible.projects, visible_tickets: visible.tickets }
      end
    end
  end
end
