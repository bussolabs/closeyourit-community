# frozen_string_literal: true

module Ticketing
  # L'UNICA porta da cui si accoda il vaglio di eleggibilità agenti (CYRA-548).
  #
  # Fino al CYRA-765 qui c'era un controllo sul servizio collegato dall'organizzazione: l'AI la
  # offre ora il sistema, quindi non c'è più niente da collegare e il vaglio si accoda sempre. Il
  # freno resta `Ai::Feature` (chiave `agent_gate`), dentro il service.
  #
  # Non accodare NON renderebbe comunque lavorabile niente: il ticket resta `pending`, e `pending` è
  # già escluso dalla coda degli agenti — è il default fail-closed della colonna a rendere sicuro il
  # non fare niente.
  module AgentEligibilityQueue
    module_function

    # → true se il vaglio è stato accodato. `wait: nil` accoda subito: è il ritorno alla valutazione
    # automatica, dove una persona sta guardando la pagina e aspetta il verdetto nuovo. Il debounce
    # serve invece a smaltire le raffiche di modifiche ravvicinate.
    def enqueue(ticket:, wait: Ticketing::Constants::AGENT_ELIGIBILITY_DEBOUNCE)
      job = Ticketing::EvaluateAgentEligibilityJob
      job = job.set(wait: wait) if wait
      job.perform_later(ticket_id: ticket.id)
      true
    end
  end
end
