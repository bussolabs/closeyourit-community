# frozen_string_literal: true

module Ticketing
  # Chiede al server AI un PARERE sull'eleggibilità agenti di un ticket (CYRA-184, CYRA-770) e lo
  # scrive nelle colonne del parere. Non muove la decisione: quella la prende una persona.
  #
  # A differenza di Ai::RunJob, questo job MANTIENE il retry di ApplicationJob (3 tentativi). Lì c'è
  # un utente che sta pollando un esito già mostrato come fallito, e ritentare pagherebbe una
  # chiamata LLM per nulla; qui non guarda nessuno, e un 429 o un 503 transitorio lascerebbe il
  # ticket permanentemente fuori dalla coda degli agenti. La guardia sul checksum rende il retry
  # idempotente e quasi gratuito: un tentativo su un ticket già valutato costa una SELECT.
  #
  # Esaurite le prove il ticket resta senza parere, e la sua decisione resta `pending`, cioè già
  # esclusa dalla coda: il fallimento definitivo è fail-closed per costruzione, senza scrivere nulla.
  class EvaluateAgentEligibilityJob < ApplicationJob
    queue_as :ai

    # Il rate limit merita un trattamento diverso dagli altri guasti. Il retry di ApplicationJob
    # riprova entro pochi secondi: contro un 429 significa bruciare i tre tentativi mentre la
    # finestra del provider è ancora chiusa — è successo davvero al primo backfill in produzione,
    # 327 esecuzioni fallite e 7 verdetti prodotti su 169. Qui si aspetta in minuti, non in secondi,
    # e si riprova più a lungo: il ticket non ha fretta, ma deve prima o poi ricevere un verdetto,
    # perché finché non ce l'ha resta fuori dalla coda degli agenti.
    # Il jitter NON è un dettaglio estetico: N job che falliscono nello stesso istante — ed è
    # esattamente ciò che fa un rate limit — riproverebbero tutti nello stesso istante, all'infinito.
    # Visto dal vivo: dopo il primo backfill i 300 ritentativi si sono addensati in una finestra di
    # otto minuti, ricreando la raffica che il rate limit aveva appena punito. La componente casuale
    # sparpaglia il gregge; la parte quadratica resta a dare l'attesa crescente.
    # Il filtro è TransientFailure e non AppError (CYRA-713): un errore definitivo — un dato che
    # non andrà mai bene — qui costerebbe sei chiamate al modello per ottenere lo stesso esito.
    # Comprende però anche i guasti di rete, che un codice non ce l'hanno: il log lo chiede con
    # `try`, altrimenti l'ultimo tentativo morirebbe di NoMethodError coprendo il guasto vero.
    retry_on TransientFailure,
             wait: ->(executions) { (executions**2).minutes + rand(0..59).seconds },
             attempts: 6 do |job, error|
      Rails.logger.warn(
        "[agent-eligibility] valutazione abbandonata per #{job.arguments.first[:ticket_id]}: #{error.try(:code) || error.class}"
      )
    end

    def perform(ticket_id:)
      ticket = Ticketing::Ticket.find_by(id: ticket_id)
      return if ticket.nil? # cancellato fra enqueue ed esecuzione: niente da valutare
      Current.organization = ticket.project.organization # runs with this organization's AI settings (CYRA-914)

      # Una persona ha già deciso: un parere non serve più a nessuno, e chiederlo costerebbe una
      # chiamata al modello per un'informazione che non entra in nessuna scelta (CYRA-770). Non è più
      # una guardia di sicurezza — il percorso automatico non può comunque toccare la decisione — è
      # solo il rifiuto di spendere per niente.
      return if ticket.agent_eligibility_source_human?

      checksum = Ticketing::AgentEligibilityText.checksum(ticket: ticket)
      # Dedupe delle tempeste di edit e dei replay: il primo job della raffica valuta e scrive il
      # checksum, gli altri escono qui.
      return if ticket.agent_eligibility_checksum == checksum

      result = Ticketing::EvaluateAgentEligibility.call(ticket: ticket)
      if Rails.env.development? && result.err? && result.error.try(:code) == "R502-LLM-002"
        # Local AI is optional. Keep the advice stale so recovery can evaluate it after setup.
        Rails.logger.info("[agent-eligibility] skipped: local AI is not configured")
        return
      end
      raise result.error if result.err? # → retry_on di ApplicationJob

      verdict = result.value
      Ticketing::SetAgentEligibility.call(
        ticket: ticket, source: :automatic, eligibility: verdict.eligibility,
        reason: verdict.reason, risks: verdict.risks, checksum: checksum
      )
    end
  end
end
