# frozen_string_literal: true

module Ticketing
  # Punto di scrittura UNICO dell'eleggibilità agenti (CYRA-184, CYRA-770). Ogni percorso — parere del
  # server AI, decisione umana, ritorno allo stato iniziale — passa da qui.
  #
  # PARERE e DECISIONE sono due cose distinte, su due coppie di colonne distinte. `agent_eligibility`
  # è la decisione, ed è il campo che la coda degli agenti interroga; `agent_eligibility_advice` è il
  # parere dell'AI, che nessuna coda legge. Prima condividevano la stessa colonna, e serviva una
  # regola di stickiness per impedire al percorso automatico di sovrascrivere una decisione umana.
  # Quella regola non c'è più perché non c'è più niente da proteggere: il percorso automatico non
  # scrive nella colonna della decisione, e questo lo garantisce la STRUTTURA, non una guardia che
  # qualcuno può dimenticare di applicare in un percorso nuovo.
  #
  # Modalità (`source`):
  #   :automatic → parere dell'AI. Scrive parere, motivo del parere, checksum del contenuto valutato
  #                e istante. NON tocca la decisione né la sua sorgente.
  #   :human     → decisione. Registra decisore e istante; NON tocca il checksum, così un eventuale
  #                reset successivo riparte da una valutazione vera e non da una stale.
  #   :reset     → azzera decisione E parere: il ticket torna com'era prima che qualcuno lo guardasse.
  #                Il chiamante ri-accoda il job.
  class SetAgentEligibility < ApplicationService
    SOURCES = %i[automatic human reset].freeze

    def initialize(ticket:, source:, eligibility: nil, reason: nil, risks: [], checksum: nil,
                   actor: nil, true_actor: nil)
      @ticket = ticket
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

      attributes = attributes_for_source
      return invalid_eligibility if attributes.nil?
      return Result.ok(@ticket) if no_change?(attributes)

      from = tracked_field_value
      ApplicationRecord.transaction do
        @ticket.update!(attributes)
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                            action: event_action, data: event_data(from))
      end
      broadcast_eligibility
      Result.ok(@ticket)
    end

    private

    # Il percorso automatico racconta il PARERE, gli altri la DECISIONE: sono due campi diversi, e un
    # evento che dicesse «il ticket è passato a lavorabile» per un parere mentirebbe a chi legge la
    # cronologia — la coda non si è mossa di un millimetro.
    def tracked_field
      @source == :automatic ? :agent_eligibility_advice : :agent_eligibility
    end

    def tracked_field_value = @ticket.public_send(tracked_field)

    def event_data(from)
      reason = @source == :automatic ? @ticket.agent_eligibility_advice_reason : @ticket.agent_eligibility_reason
      { tracked_field => { from: from, to: tracked_field_value },
        reason: reason, risks: @risks.presence }.compact
    end

    def attributes_for_source
      case @source
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
