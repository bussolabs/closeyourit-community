# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-739 — le tre porte dell'assistente sui ticket: l'analisi rapida di una segnalazione, la
    # composizione dell'intero ticket dal testo libero e la domanda in linguaggio naturale
    # sull'archivio. Tutte e tre accodano un lavoro e rispondono subito: l'esito si legge poi
    # sull'esito della richiesta, e nessuna tiene occupato un thread web mentre il modello pensa.
    module Assistants
      extend ActiveSupport::Concern

      # Assistente AI bug-report rapido: analizza il testo libero e ritorna i 4 campi GWT (se
      # ricostruibili) oppure domande di chiarimento. Draft NON persistito (nessun ticket creato).
      # Aperto a tutti i ruoli che possono aprire ticket; gated dal flag quick_bug_report del progetto.
      def analyze
        project = visible.projects.find_by(id: params[:project_id])
        return render_analyze_error("R404-TICKET-002", :not_found, t("member.tickets.analyze.errors.project")) if project.nil?

        unless project.quick_bug_report_enabled?
          return render_analyze_error("R422-TICKET-002", :unprocessable_content, t("member.tickets.analyze.errors.disabled"))
        end

        enqueue_ai_request!(kind: "ticket_analyze", args: { project_id: project.id, text: params[:quick_text].to_s })
      end

      # AI Buddy: dal testo libero l'assistente compone l'INTERO ticket (titolo, tipo, descrizione +
      # clausole GWT per i bug). Draft NON persistito. A differenza di #analyze NON serve un flag di
      # progetto: basta un progetto visibile selezionato (anti-BOLA 404). Testo vuoto → 422 sincrono
      # (niente job sprecato). Enqueue async → l'esito si polla su GET /member/ai/requests/:id, il JS
      # riempie il form. Aperto a tutti i ruoli che possono aprire ticket (baseline dello scope).
      def compose
        project = visible.projects.find_by(id: params[:project_id])
        return render_analyze_error("R404-TICKET-002", :not_found, t("member.tickets.compose.errors.project")) if project.nil?

        if params[:text].to_s.strip.blank?
          return render_analyze_error("R422-TICKET-012", :unprocessable_content, t("member.tickets.compose.errors.blank"))
        end

        # La bozza da correggere si RILEGGE dalla richiesta precedente, scoped all'account (CYRA-632):
        # il client manda solo l'id. Rimandarcela sarebbe un payload da qualche KB a ogni correzione, e
        # soprattutto ci farebbe scrivere nel prompt un testo che chiunque può sostituire dal
        # DevTools — mentre quello che c'è in Ai::Request l'abbiamo prodotto noi.
        previous = previous_compose_draft
        if previous == :missing
          return render_analyze_error("R404-AI-001", :not_found,
                                      t("member.tickets.compose.errors.previous_missing"))
        end

        # I due campi della correzione entrano SOLO quando c'è una correzione: al primo giro args resta
        # identico a com'era prima di CYRA-632. Non è pulizia estetica — args è la storia leggibile di
        # cosa è stato chiesto, e una `correction: ""` su ogni riga la rende illeggibile proprio a chi
        # cerca i pochi casi in cui una correzione c'è stata davvero.
        args = { project_id: project.id, text: params[:text].to_s }
        args.merge!(correction: params[:correction].to_s, previous_draft: previous) if previous

        enqueue_ai_request!(kind: "ticket_compose", args: args)
      end

      # Pagina RAG "chiedi ai ticket" (read-only sui ticket visibili: nessun gate oltre l'auth).
      def ask
        # CYRA-396 — le domande già fatte restano consultabili: prima ogni visita ripartiva dal campo
        # bianco. Vengono dalle richieste dell'account, non da una tabella nuova.
        @recent_questions = ::Ai::Request.where(account_id: Current.account.id, kind: "ticket_ask")
                                         .order(created_at: :desc).limit(20)
                                         .filter_map { |request| request.args["question"].presence }
                                         .uniq.first(5)
      end

      # Domanda in NL: accoda Ai::RunJob (kind ticket_ask) e risponde 202 con request_id; la UI polla
      # l'esito su GET /member/ai/requests/:id. ASINCRONO come #compose (CYRA-275): una domanda AI lenta
      # non tiene più occupato un thread web per minuti — la richiesta ritorna subito, il worker fa la
      # chiamata al modello. Lo scope visibile è AUTORIZZATO QUI (Current regge god/impersonation) e
      # passato come project_ids: il job parte da lì e non ricalcola da zero. È però un TETTO, non un
      # lasciapassare (CYRA-812) — il job lo interseca col perimetro di allora, per cui accodiamo anche
      # chi ha autorizzato la domanda (ai_scope_args). Testo vuoto → 422 sincrono (niente job sprecato).
      def ask_query
        question = params[:question].to_s
        if question.strip.blank?
          return render_analyze_error("R422-TICKET-005", :unprocessable_content, t("member.tickets.ask.errors.blank"))
        end

        enqueue_ai_request!(kind: "ticket_ask", args: { question: }.merge(ai_scope_args))
      end

      private

      # → nil (nessuna correzione in corso), l'Hash della bozza precedente, o :missing quando l'id
      # non risolve nulla di nostro. Il caso :missing è un 404 e non un «va bene lo stesso, componi da
      # capo»: chi ha premuto «riscrivi con la correzione» aspetta la sua bozza corretta, e riceverne
      # una scritta da zero senza avviso è peggio di un errore.
      #
      # Tre condizioni insieme, non una: `for` è l'anti-BOLA (mai la richiesta di un altro account),
      # il kind evita di dare in pasto al prompt il payload di un triage errori, e done perché una
      # richiesta ancora pending non ha nessuna bozza da correggere.
      def previous_compose_draft
        id = params[:previous_request_id].to_s
        return if id.blank? || params[:correction].to_s.strip.blank?

        request_record = ::Ai::Request.for(account: Current.account, organization: Current.organization)
                                      .status_done.find_by(id: id, kind: "ticket_compose")
        request_record&.payload.presence || :missing
      end

      def render_analyze_error(code, status, message)
        render json: { error: { code:, message: } }, status:
      end
    end
  end
end
