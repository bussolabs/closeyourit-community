# frozen_string_literal: true

module Home
  module Approvals
    # Esegue una decisione della pagina Approvazioni (CYRA-262). Non contiene logica di dominio —
    # sceglie il service giusto secondo famiglia e fase e gli passa la parola. Il gate è già stato
    # applicato da Home::Approvals::Detail, che risolve la card dagli scope visibili: card assente
    # = 404, non 403.
    #
    # Le azioni veloci inline della home NON passano di qui, deliberatamente: la home usa l'endpoint
    # di review anche per approvare il lavoro dell'autopilot, dove a decidere è il CTO effettivo e non
    # il revisore designato del ticket — passare da Detail#review_card (che esige reviewer_id) le
    # spegnerebbe. Là restano sei chiamate dirette ai service di dominio; qui c'è il ventaglio più
    # largo (note, domande, fasi bloccate) che quella riga non offre.
    #
    #   Home::Approvals::Decide.call(account:, organization:, visible_projects:, visible_tickets:,
    #     key: "review:…", decision: :approve, text: "…") → Result
    class Decide < ApplicationService
      # L'azione di cronologia che segna "ho chiesto precisazioni": il testo vive nel commento, qui
      # resta il fatto. È anche il segnale che Home::Approvals::Queue legge per mettere la riga in
      # attesa di risposta invece che in cima alla pila.
      ASK_ACTION = "clarification_requested"

      DECISIONS = %i[approve reject ask reply reassess].freeze

      # Il registro: decisione → metodo che la esegue, sulle stesse chiavi di DECISIONS (una spec le
      # confronta). Col nome composto a runtime nessuno dei cinque risultava chiamato da nessuna
      # parte. CYRA-801
      DECISION_HANDLERS = { approve: :approve_on, reject: :reject_on, ask: :ask_on,
                            reply: :reply_on, reassess: :reassess_on }.freeze

      # `broadcast_dependents: false` lo passa solo BulkApprove: con più card nella stessa richiesta il
      # refresh delle board dei dependents va fatto una volta sul lotto, non una per card (N+1).
      # `target_status:` too: the review destination is read once for the whole selection. CYRA-1048
      def initialize(account:, organization:, visible_projects:, visible_tickets:, key:, decision:,
                     text: nil, true_actor: nil, card: nil, broadcast_dependents: true, target_status: nil)
        @account = account
        @organization = organization
        @visible_projects = visible_projects
        @visible_tickets = visible_tickets
        @key = key
        @decision = decision.to_s.to_sym
        @text = text.to_s.strip
        @true_actor = true_actor
        @card = card
        @broadcast_dependents = broadcast_dependents
        @target_status = target_status
      end

      def call
        return unknown_decision unless DECISIONS.include?(@decision)

        card = resolve_card
        return not_found if card.blank?
        return forbidden unless card.can?(@decision)

        # Una decisione inventata è già uscita sopra: il `fetch` parla solo se registro e DECISIONS
        # divergono. CYRA-801
        send(DECISION_HANDLERS.fetch(@decision), card)
      end

      private

      # Una card già risolta si accetta così com'è (CYRA-284: l'accettazione in blocco la risolve per
      # decidere se è idonea, e rirosolverla qui sarebbe lo stesso lavoro due volte). Non è una
      # scorciatoia al gate: chi la passa l'ha avuta da Detail con gli STESSI scope visibili.
      def resolve_card
        @card || Detail.call(account: @account, organization: @organization, visible_projects: @visible_projects,
                             visible_tickets: @visible_tickets, key: @key)
      end

      # --- Accettazione ------------------------------------------------------------------------
      # La nota è facoltativa e NON è un campo del dominio: diventa un commento sul ticket, così la
      # legge anche l'automa che poi esegue. Si scrive PRIMA della decisione: se l'approvazione
      # fallisce (piano già deciso da un altro, lock, race) la nota resta senza effetto ma visibile,
      # mentre il contrario — decisione presa e nota persa — cancellerebbe l'unica istruzione data.
      def approve_on(card)
        note = @text
        case card.kind
        when "agent_plan" then approve_plan(card, note)
        when "review" then with_note(card, note) { approve_review(card) }
        when "secret_change" then Secrets::ChangeRequests::Approve.call(change_request: card.record, actor: @account)
        end
      end

      # A review bloccata non c'è un piano da approvare: si rimette in coda la lavorazione.
      def approve_plan(card, note)
        return with_note(card, note) { approve_review(card) } if
          card.phase == "awaiting_autopilot_approval"
        return with_note(card, note) { Agents::Workflows::Unblock.call(workflow: card.record, actor: @account) } if
          card.phase == "review_blocked"

        with_note(card, note) { Agents::Workflows::ApprovePlan.call(workflow: card.record, actor: @account) }
      end

      # --- Rifiuto -----------------------------------------------------------------------------
      # Il motivo è sempre obbligatorio: lo impongono già i service di dominio, ma fermarsi qui evita
      # di scrivere un commento per una decisione che poi fallisce.
      def reject_on(card)
        return missing_reason if @text.blank?

        case card.kind
        when "agent_plan" then reject_plan(card)
        when "review" then Ticketing::RejectReview.call(**review_args(card), reason: @text)
        when "secret_change"
          Secrets::ChangeRequests::Reject.call(change_request: card.record, actor: @account, reason: @text)
        end
      end

      # "Respingi" su un'analisi vuol dire rifalla: il piano torna al planner e ne nasce una nuova
      # versione. A review bloccata non esiste una versione da rifare — l'unico rifiuto possibile è
      # annullare la lavorazione (e lo può fare solo admin/owner, vedi Detail#plan_decisions).
      def reject_plan(card)
        case card.phase
        when "awaiting_autopilot_approval" then Ticketing::RejectReview.call(**review_args(card), reason: @text)
        when "review_blocked" then Agents::Workflows::Cancel.call(workflow: card.record, actor: @account, reason: @text)
        else Agents::Workflows::RequestPlanChanges.call(workflow: card.record, actor: @account, reason: @text)
        end
      end

      # --- Domanda e risposta ------------------------------------------------------------------
      # Chiedere precisazioni non cambia lo stato del dominio: pubblica la domanda nella discussione
      # del ticket e la segna in cronologia. La card resta in pila, ma in fondo, finché non risponde
      # qualcuno. NIENTE marker automation sul commento: è una domanda umana e deve notificare i
      # watcher come tutte le altre. Su un ticket con una domanda dell'automa ancora aperta l'azione
      # non è nemmeno offerta (Detail#askable): là il commento sarebbe letto come la risposta.
      #
      # Commento ed evento non sono in una transazione unica: Ticketing::AddComment notifica e
      # broadcasta assumendo di aver già committato, e avvolgerlo romperebbe quel contratto. Se
      # RecordActivity fallisce — l'action è nell'allow-list e l'org combacia, quindi solo per un bug —
      # l'eccezione propaga e si vede: la domanda resta pubblicata e visibile, senza il badge "in
      # attesa". Perdere il badge è meno grave che ingoiare l'errore o rinunciare al broadcast.
      def ask_on(card)
        return missing_text if @text.blank?

        result = Ticketing::AddComment.call(ticket: card.ticket, author: @account, params: { body: @text })
        return result if result.err?

        Ticketing::RecordActivity.call(ticket: card.ticket, action: ASK_ACTION, actor: @account,
                                       true_actor: @true_actor, data: { comment_id: result.value.id })
        result
      end

      # Risposta a una domanda dell'automa: è AddComment a collegarla alla clarification aperta e a
      # rimettere il ticket in coda (capture_clarification_response). Qui non c'è nulla da aggiungere.
      def reply_on(card)
        return missing_text if @text.blank?

        Ticketing::AddComment.call(ticket: card.ticket, author: @account, params: { body: @text })
      end

      # --- Rivalutazione -----------------------------------------------------------------------
      # CYRA-675 — «serve ancora, o è già fatto?». Non chiede testo e non è un giudizio sul lavoro di
      # nessuno: rimanda la lavorazione alla pianificazione, che rilegge il codice di oggi. Solo sul
      # ramo agent_plan — su una review si sta decidendo di codice già scritto, e su una domanda
      # aperta l'unico gesto è rispondere.
      def reassess_on(card)
        return unsupported unless card.kind == "agent_plan"

        Agents::Workflows::Reassess.call(workflow: card.record, actor: @account)
      end

      # --- Helper ------------------------------------------------------------------------------

      # La nota di accompagnamento all'accettazione. Se il commento fallisce (corpo invalido) la
      # decisione non parte: meglio ripetere che decidere perdendo per strada le istruzioni.
      def with_note(card, note)
        if note.present?
          comment = Ticketing::AddComment.call(ticket: card.ticket, author: @account, params: { body: note })
          return comment if comment.err?
        end
        yield
      end

      def approve_review(card)
        Ticketing::ApproveReview.call(**review_args(card), broadcast_dependents: @broadcast_dependents,
                                                           target_status: @target_status)
      end

      def review_args(card)
        { organization: @organization, ticket: card.ticket, actor: @account, true_actor: @true_actor }
      end

      def not_found
        Result.err(AppError.new(I18n.t("member.approvals.errors.not_found"),
                                code: "R404-APPROVAL-001", status: :not_found))
      end

      def forbidden
        Result.err(AppError.new(I18n.t("member.approvals.errors.forbidden"),
                                code: "R403-APPROVAL-001", status: :forbidden))
      end

      def unknown_decision
        Result.err(AppError.new(I18n.t("member.approvals.errors.unknown_decision"), code: "R422-APPROVAL-001"))
      end

      def missing_reason
        Result.err(AppError.new(I18n.t("member.approvals.errors.missing_reason"), code: "R422-APPROVAL-002"))
      end

      def missing_text
        Result.err(AppError.new(I18n.t("member.approvals.errors.missing_text"), code: "R422-APPROVAL-003"))
      end

      def unsupported
        Result.err(AppError.new(I18n.t("member.approvals.errors.unknown_decision"), code: "R422-APPROVAL-004"))
      end
    end
  end
end
