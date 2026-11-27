# frozen_string_literal: true

module Ticketing
  # Single locked writer for advice, human decisions, automatic approval and withdrawal.
  # Advice must match current content; automatic decisions never override a person. CYRA-1219.
  # `locked: true` is for a caller that already holds the ticket's row lock: locking again would
  # reload the ticket and drop the uploads of files it has just attached.
  class SetAgentEligibility < ApplicationService
    SOURCES = %i[automatic human reset go_ahead invalidate].freeze

    def initialize(ticket:, source:, eligibility: nil, reason: nil, risks: [], checksum: nil,
                   actor: nil, true_actor: nil, locked: false)
      @ticket = ticket
      @locked = locked
      @source = source.to_sym
      @eligibility = eligibility&.to_s
      @reason = reason
      @risks = Array(risks)
      @checksum = checksum
      @actor = actor
      @true_actor = true_actor
    end

    def call
      return invalid_source unless SOURCES.include?(@source)

      return write_locked if @locked

      @ticket.with_lock { write_locked }
    end

    private

    def write_locked
      return Result.ok(@ticket) if @source == :automatic && @checksum != AgentEligibilityText.checksum(ticket: @ticket)

      attributes = attributes_for_source
      return invalid_eligibility if attributes.nil?
      return Result.ok(@ticket) if no_change?(attributes)

      from = tracked_field_value
      ApplicationRecord.transaction do
        @ticket.update!(attributes)
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                            actor_name: (I18n.t("agents.supporter.activity_actor") if automatic_decision?),
                            action: event_action, data: event_data(from)) unless from == tracked_field_value && automatic_decision?
      end
      ActiveRecord.after_all_transactions_commit { broadcast_eligibility }
      Result.ok(@ticket)
    end

    def automatic_decision? = %i[go_ahead invalidate].include?(@source)

    # Il percorso automatico racconta il PARERE, gli altri la DECISIONE: sono due campi diversi, e un
    # evento che dicesse «il ticket è passato a lavorabile» per un parere mentirebbe a chi legge la
    # cronologia — la coda non si è mossa di un millimetro.
    def tracked_field
      @source == :automatic ? :agent_eligibility_advice : :agent_eligibility
    end

    def tracked_field_value = @ticket.public_send(tracked_field)

    def event_data(from)
      reason = @source == :automatic ? @ticket.agent_eligibility_advice_reason : @ticket.agent_eligibility_reason
      data = { tracked_field => { from: from, to: tracked_field_value }, reason: reason, risks: @risks.presence }.compact
      if automatic_decision?
        data.merge!(go_ahead: @ticket.agent_eligibility_allowed? ? "automatic" : "withdrawn",
                    advice_reason: @ticket.agent_eligibility_advice_reason,
                    advice_checksum: @ticket.agent_eligibility_checksum,
                    advice_evaluated_at: @ticket.agent_eligibility_evaluated_at)
        data[:withdrawn_because] = withdrawn_because unless @ticket.agent_eligibility_allowed?
      end
      data
    end

    # CYRA-1219 — a change to the text takes it back before any new advice; otherwise the advice did.
    def withdrawn_because = @source == :invalidate ? "content_changed" : "advice"

    def attributes_for_source
      case @source
      when :go_ahead
        AutoDecideAgentEligibility.new(ticket: @ticket).attributes
      when :invalidate
        invalidation_attributes
      when :reset
        { agent_eligibility: :pending, agent_eligibility_source: :automatic,
          agent_eligibility_reason: nil, agent_eligibility_checksum: nil,
          agent_eligibility_evaluated_at: nil, agent_eligibility_decided_at: nil,
          agent_eligibility_decided_by: nil,
          agent_eligibility_advice: :unknown, agent_eligibility_advice_reason: nil }
      when :automatic
        return unless valid_eligibility?

        { agent_eligibility_advice: @eligibility, agent_eligibility_advice_reason: @reason,
          agent_eligibility_checksum: @checksum, agent_eligibility_evaluated_at: Time.current }
      when :human
        return unless valid_eligibility?

        { agent_eligibility: @eligibility, agent_eligibility_source: :human,
          agent_eligibility_reason: @reason, agent_eligibility_decided_at: Time.current,
          agent_eligibility_decided_by: @actor }
      end
    end

    def invalidation_attributes
      return {} unless @ticket.agent_eligibility_source_automatic? && @ticket.agent_eligibility_allowed? && @ticket.agent_eligibility_stale?

      { agent_eligibility: :pending, agent_eligibility_reason: nil,
        agent_eligibility_decided_at: nil, agent_eligibility_decided_by: nil }
    end

    # Un umano può portare un ticket a pending? No: per quello c'è :reset, che pulisce anche il
    # checksum. Consentirlo qui lascerebbe un pending con checksum valido, cioè un ticket fuori dalla
    # coda che nessuna rivalutazione andrebbe mai a ripescare. Vale anche per il parere: `unknown`
    # non è un verdetto che il modello possa esprimere, è l'assenza di verdetto.
    def valid_eligibility?
      %w[allowed blocked].include?(@eligibility)
    end

    # No-op quando nulla cambia davvero: evita eventi di cronologia e broadcast a vuoto sui replay
    # del job (che è idempotente per costruzione).
    def no_change?(attributes)
      attributes.all? do |key, value|
        current = @ticket.public_send(key)
        key.to_s.end_with?("_at") ? true : current.to_s == normalized(key, value).to_s
      end
    end

    def normalized(key, value)
      return value&.id if key == :agent_eligibility_decided_by

      value
    end

    # `agent_eligibility_evaluated` è il parere dell'AI: lo produce SOLO il percorso automatico.
    # L'azzeramento lo preme una persona — cancella una decisione e rimette il ticket in attesa — e
    # registrarlo come «evaluated» lo attribuirebbe al modello: nella cronologia comparirebbe il
    # robot al posto di chi ha davvero premuto, che è il contrario di quello che serve a chi indaga.
    def event_action
      @source == :automatic ? "agent_eligibility_evaluated" : "agent_eligibility_overridden"
    end

    # Replace realtime del pannello "Agenti AI" della show: parere e decisione arrivano da percorsi
    # diversi (un job il primo, una persona il secondo), quindi chi ha la pagina aperta li vede
    # comparire senza ricaricare. Il target è il div di _agent_eligibility, che sta DENTRO
    # _agent_eligibility_panel ma non ne contiene i pulsanti di override (per-viewer): un broadcast
    # non sa chi guarda, quindi non deve poterli toccare.
    def broadcast_eligibility
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.ticket(@ticket),
        target: "#{ActionView::RecordIdentifier.dom_id(@ticket)}_agent_eligibility",
        partial: "member/tickets/agent_eligibility",
        locals: { ticket: @ticket }
      )
    end

    def invalid_source
      Result.err(AppError.new("Sorgente di eleggibilità non valida", code: "R422-TICKET-012"))
    end

    def invalid_eligibility
      Result.err(AppError.new("Eleggibilità non valida", code: "R422-TICKET-013"))
    end
  end
end
