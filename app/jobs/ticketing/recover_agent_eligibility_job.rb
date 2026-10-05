# frozen_string_literal: true

module Ticketing
  # Recupero automatico dei PARERI di eleggibilità mai prodotti (CYRA-847).
  #
  # Gemello di Ticketing::BackfillEmbeddingsJob e nato per la stessa ragione (CYRA-232): senza questo
  # giro, un ticket la cui valutazione è fallita durante un guasto del server AI resta senza parere
  # PER SEMPRE. `R502-LLM-002` è classificato definitivo (TransientFailure::DEFINITIVE_CODES), quindi
  # EvaluateAgentEligibilityJob non ritenta nemmeno una volta; il gate è fail-closed e la decisione
  # resta `pending`, cioè già esclusa dalla coda degli agenti. L'unico rimedio era il rake
  # `agent_eligibility:backfill` lanciato a mano, quando qualcuno se ne accorgeva: in cinque settimane
  # è successo 2.372 volte (error group CYRA 6c7308dc).
  #
  # Idempotente come il gemello degli embedding: accoda solo i ticket la cui valutazione è stale, e il
  # job a valle ri-controlla la guardia sul checksum prima di spendere una chiamata al modello.
  #
  # PERIMETRO STRETTO, e non è un dettaglio: qui entrano solo i ticket SENZA PARERE
  # (`agent_eligibility_advice` = unknown), cioè esattamente la finestra di guasto. Un parere che
  # esiste ma è vecchio non rende invisibile niente — il ticket si vede e una persona può decidere —
  # e includerlo qui farebbe passare da questo giro anche la rivalutazione dell'intero parco dopo un
  # bump di AgentEligibilityText::PROMPT_VERSION, cioè una chiamata al modello per ogni ticket già
  # valutato. Quella resta una scelta deliberata, e il suo strumento è il rake.
  class RecoverAgentEligibilityJob < ApplicationJob
    queue_as :batch

    def perform
      total = 0
      recoverable.find_each do |ticket|
        # La staleness si legge in Ruby perché il checksum è uno SHA calcolato lato app, non
        # filtrabile in SQL. Il predicato salta da sé le decisioni umane (sticky).
        next unless ticket.agent_eligibility_stale?

        # CADENZATO come il backfill a mano: al primo backfill reale 169 job partiti insieme hanno
        # saturato il rate limit del fornitore in pochi secondi. Il tetto per giro tiene la punta
        # bassa, la cadenza la spalma sui minuti.
        wait = (total / Ticketing::Constants::AGENT_ELIGIBILITY_BACKFILL_PER_MINUTE).minutes
        Ticketing::EvaluateAgentEligibilityJob.set(wait: wait).perform_later(ticket_id: ticket.id)
        total += 1
        break if total >= Ticketing::Constants::AGENT_ELIGIBILITY_RECOVERY_PER_RUN
      end

      return if total.zero?

      Rails.logger.info("[agent-eligibility] recupero: riaccodata la valutazione di #{total} ticket senza parere")
    end

    private

    # Solo i ticket APERTI: quelli in lavorazione hanno già qualcuno addosso, i chiusi non entrano
    # comunque nella coda degli agenti. Stessa scelta (e stesse ragioni) del default del rake.
    # Il preload copre tutto ciò che entra nel checksum: senza, è un N+1 sull'intero backlog aperto.
    def recoverable
      Ticketing::Ticket
        .joins(:status)
        .includes(:scenarios, :conditions)
        .with_attached_files
        .where(types_ticket_statuses: { category: Types::TicketStatus.categories.fetch("open") })
        .where(agent_eligibility_advice: :unknown)
        .where(agent_eligibility_source: :automatic)
    end
  end
end
