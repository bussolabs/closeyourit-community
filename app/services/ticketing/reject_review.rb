# frozen_string_literal: true

module Ticketing
  # Respinge la review di un ticket: dal suo status review-gate lo riporta sul primo status
  # in_progress non-gate (per position), con motivo OBBLIGATORIO. In un colpo solo: evento
  # `review_rejected` (fatto + reason snapshottata per audit) e motivo pubblicato dove si legge —
  # commento in discussione se è un messaggio breve, versione del resoconto se è lungo (vedi
  # #publish_reason). Il ping dedicato all'assignee parte dal NotifyJob (vedi
  # Notifications::DispatchEvent). Result pattern, broadcast come ChangeStatus.
  class RejectReview < ApplicationService
    include StatusBroadcasts
    include ::Agents::Workflows::ConcludedTicketGate

    # `mode` distingue i due rifiuti possibili su una lavorazione automatica:
    #   :rework — rimandala al lavoro. Il motivo scritto qui resta sul ticket e l'agente lo legge al
    #             giro dopo (commento o resoconto, vedi #publish_reason); la fase torna in coda e la
    #             bocciatura conta nel budget, così due rifiuti di fila fermano comunque tutto.
    #   :hold   — mettila da parte per una persona. Il ticket torna in lavorazione ma nessuno lo
    #             ripropone alle macchine.
    # Default :hold, che è il comportamento storico: un canale che non conosce ancora questa scelta
    # (la CLI, un'integrazione) non deve far ripartire lavorazioni senza averlo chiesto.
    MODES = %i[rework hold].freeze

    def initialize(organization:, ticket:, reason:, actor: nil, true_actor: nil, mode: :hold)
      @organization = organization
      @ticket = ticket
      # Fine-riga normalizzati QUI, una volta (CYRA-389): la textarea manda CRLF, il commento e il
      # resoconto misurano il testo con LF, e la scelta di dove finisce la motivazione dipende dalla
      # sua lunghezza. Misurare il testo grezzo e farlo validare normalizzato vuol dire instradare
      # verso il commento un testo che il commento poi rifiuta, un carattere per riga alla volta.
      @reason = LengthBudget.normalize_newlines(reason).strip
      @actor = actor
      @true_actor = true_actor
      @mode = MODES.include?(mode.to_s.to_sym) ? mode.to_s.to_sym : :hold
    end

    def call
      # CYRA-630 — la stessa guardia del gemello che approva: su un ticket concluso non si decide.
      # Qui il rifiuto arrivava già, ma per il motivo sbagliato — «non c'è uno status in cui
      # respingere» invece di «il ticket è chiuso» — e chi leggeva andava a cercare nel posto sbagliato.
      return concluded_ticket if concluded_ticket?

      unless @ticket.status&.review_gate?
        return Result.err(AppError.new(I18n.t("member.tickets.errors.not_in_review"), code: "R422-TICKET-006"))
      end
      if @reason.blank?
        return Result.err(AppError.new(I18n.t("member.tickets.errors.reason_required"), code: "R422-TICKET-007"))
      end
      # Il tetto è quello del resoconto, dove la motivazione lunga finisce (CYRA-389). Il guard sta
      # PRIMA della transazione, non dopo: oltre soglia chi respinge riceve l'errore con il testo
      # ancora nella casella, invece di un respingimento fatto e una motivazione perduta.
      if @reason.length > Constants::REVIEW_REASON_MAX_CHARS
        return Result.err(AppError.new(
                            I18n.t("member.tickets.errors.reason_too_long",
                                   count: Constants::REVIEW_REASON_MAX_CHARS, actual: @reason.length),
                            code: "R422-TICKET-018"
                          ))
      end

      target = target_status
      if target.nil?
        return Result.err(AppError.new(I18n.t("member.tickets.errors.no_target_status"), code: "R422-TICKET-008"))
      end

      from_status = @ticket.status
      event = nil
      ApplicationRecord.transaction do
        @ticket.update!(status: target)
        requeue_agent_phase! if @mode == :rework
        event = RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                                    action: "review_rejected",
                                    data: { status: { from: from_status.label, to: target.label },
                                            reason: @reason, mode: @mode.to_s })
      end
      # Post-commit: notifiche (ping assignee + watcher), motivo pubblicato, board realtime.
      Ticketing::NotifyJob.perform_later(event_id: event.id)
      publish_reason
      broadcast_status_change(ticket: @ticket)
      Result.ok(@ticket)
    end

    private

    # Rimette la lavorazione automatica in coda sulla fase che è stata rifiutata.
    #
    # Quale fase: quella conclusa e in attesa di approvazione, cioè l'ULTIMA che il claim ha avviato e
    # per cui la coda non propone più nulla. `ready_execution_phase` a questo punto è nil proprio per
    # quel motivo, quindi la si cerca a ritroso fra le fasi eseguibili.
    #
    # Il budget riparte (`cleared_block`) perché il rifiuto è una persona che dice "rifallo": ripartire
    # con il conteggio già a uno concederebbe un solo tentativo invece dei due dichiarati. È la stessa
    # scrittura che fa Agents::Workflows::Unblock, e sta nella stessa transazione del cambio di stato:
    # o vale tutto, o niente.
    def requeue_agent_phase!
      workflow = @ticket.agent_workflow
      return if workflow.nil? || workflow.terminal?

      phase = Agents::Workflow::PHASE_START_COLUMNS.keys.reverse.find do |candidate|
        columns = Agents::Workflow::PHASE_START_COLUMNS.fetch(candidate)
        workflow[columns[:started]].present?
      end
      return if phase.nil?

      workflow.update!(**Agents::Workflow.cleared_block)
      workflow.send_phase_back_to_work!(phase)
    end

    # Destinazione risolta per semantica (category), MAI per code hardcoded: gli status sono
    # lookup per-org rinominabili. Primo attivo in_progress non review-gate per position.
    def target_status
      @organization.ticket_statuses.active.where(review_gate: false).category_in_progress.ordered.first
    end

    # Dove finisce il testo del respingimento, e perché in due posti diversi (CYRA-389).
    #
    # Un motivo BREVE è un messaggio: sta nella discussione, dove chi apre il ticket lo trova subito e
    # dove lo rilegge l'agente al giro dopo. Un motivo LUNGO nella discussione non ci sta — il tetto
    # del commento è 240 caratteri per scelta (Ticketing::Constants::COMMENT_MAX_CHARS) — e prima finiva in
    # un warn nei log: la motivazione restava solo nel jsonb dell'evento, che nessuna pagina mostra,
    # quindi il perché di un lavoro respinto usciva dal prodotto proprio quando era tutto il valore
    # del gesto. Va nel resoconto, che è il posto del testo lungo di questo ticket e si legge anche
    # dalla CLI; in discussione RecordReport lascia comunque la riga di servizio che dice dov'è.
    #
    # Post-commit e non bloccante in entrambi i rami: la reason è già snapshottata nell'evento
    # (audit), e un fallimento qui non deve annullare un respingimento ormai committato.
    def publish_reason
      result = publish_result
      return unless result.err?

      Rails.logger.warn("RejectReview: motivo non pubblicato (ticket=#{@ticket.id}, code=#{result.error.code})")
    end

    def publish_result
      if @reason.length > Ticketing::Constants::COMMENT_MAX_CHARS
        return RecordReport.call(ticket: @ticket, author: @actor, body: @reason, source: :review_rejection)
      end

      AddComment.call(ticket: @ticket, author: @actor, params: { body: @reason })
    end
  end
end
