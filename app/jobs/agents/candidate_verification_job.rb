# frozen_string_literal: true

module Agents
  # CYRA-614 — va a guardare le proposte consegnate e non ancora verificate.
  #
  # Due ingressi, e servono entrambi: la consegna lo accoda subito dopo il commit (così nel caso
  # normale non si aspetta il giro), e un ricorrente ripassa le righe scadute (così una consegna
  # arrivata mentre il lavoro era giù non resta lì per sempre). Il secondo senza il primo farebbe
  # aspettare fino a un minuto ogni lavoro; il primo senza il secondo perderebbe tutto ciò che
  # succede quando il job muore.
  #
  # Nessun esito passa da un'eccezione: un job che solleva ritenta tre volte e poi tace, e il
  # silenzio qui sarebbe indistinguibile da «tutto a posto». Verify scrive sempre uno stato.
  class CandidateVerificationJob < ApplicationJob
    queue_as :maintenance

    # Quante righe per giro. Un tetto c'è perché ogni riga costa una chiamata a GitHub: senza, un
    # arretrato le farebbe partire tutte insieme e il rate limit le farebbe fallire in blocco.
    BATCH = 50

    def perform(candidate_id = nil)
      candidates = candidate_id ? Agents::DeliveryCandidate.where(id: candidate_id) : due_records

      # Il lotto è già limitato: find_each scarterebbe l'ordine di scadenza.
      candidates.each do |candidate|
        Agents::Candidates::Verify.call(candidate:)
      rescue StandardError => e
        # Una riga che esplode non deve portarsi dietro le altre del lotto: si scrive e si va avanti.
        Rails.logger.error("Agents::CandidateVerificationJob: #{candidate.id} #{e.class}: #{e.message}")
      end
    end

    private

    def due_records = Agents::DeliveryCandidate.due.order(:next_check_at).limit(BATCH)
  end
end
