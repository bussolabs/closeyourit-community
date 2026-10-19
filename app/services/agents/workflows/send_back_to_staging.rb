# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1030 — «Rimanda allo staging»: un rilascio fermo in produzione per un difetto nel codice
    # preparato torna alla prova, che preparerà un codice nuovo.
    #
    # «Riprova» (Unblock) riapre solo la produzione, sullo stesso codice sigillato: il guasto si ripete.
    # Annullare butterebbe via triage, piano e codice già approvati. Qui si cancella il tentativo in
    # produzione E la conclusione della prova — data, verifica, numero sigillato, prova del rilascio
    # ancora aperta — così niente di vecchio può far ripartire la produzione sul codice difettoso, e
    # la fila dei rilasci del repository (ProductionLock) si libera. Decide il CTO effettivo.
    class SendBackToStaging < ApplicationService
      include CtoGate
      include ConcludedTicketGate

      # Attributi della produzione da azzerare: avvio, fine e autore. Diretti e non con
      # #send_phase_back_to_work!, che chiede un avvio scritto — dopo un rilascio fallito
      # ReportFailure e MarkStale l'hanno già azzerato.
      PRODUCTION_CLEARED = {
        closer_production_started_at: nil, closer_production_completed_at: nil,
        closer_production_by_host_id: nil, closer_production_by_service_account_id: nil
      }.freeze

      # La prova che la prova era riuscita (Staging::VerifyMerge): lasciarla vorrebbe dire una
      # produzione proposta prima che la prova sia rifatta.
      STAGING_PROOF_CLEARED = {
        closer_staging_verified_at: nil, closer_staging_next_check_at: nil,
        closer_staging_last_error_code: nil, closer_staging_checks_count: 0
      }.freeze

      def initialize(workflow:, actor:, now: Time.current)
        @workflow = workflow
        @actor = actor
        @now = now
      end

      def call
        return forbidden unless authorized_cto?
        return concluded_ticket if concluded_ticket?

        sent_back = false
        ApplicationRecord.transaction do
          @workflow.lock!
          # Due clic ravvicinati: il secondo trova la lavorazione già in coda per la prova, e non la
          # rimanda indietro una seconda volta.
          return not_stopped unless @workflow.stopped_in_production?

          landed_at = @workflow.closer_staging_verified_at || @now
          @workflow.update!(**Agents::Workflow.cleared_block(@now), **PRODUCTION_CLEARED, **STAGING_PROOF_CLEARED)
          # Lo stesso gesto del rifiuto della revisione (Ticketing::RejectReview): la fase conclusa
          # torna al lavoro. Una prova mai avviata non ha niente da rifare: non si tocca niente.
          raise ActiveRecord::Rollback unless @workflow.send_phase_back_to_work!("closer_staging")

          @workflow.reload
          raise ActiveRecord::Rollback unless release_numbers!(landed_at)

          close_live_probes!
          sent_back = true
        end
        unless sent_back
          @workflow.reload
          return @number_taken ? number_taken : not_stopped
        end

        project_status
        Result.ok(@workflow)
      end

      private

      # L'assegnazione della produzione conserva il vecchio punto di codice, e Releases::Assign la
      # riusa sempre: va tolta, e la prossima leggerà il commit della nuova prova. Il numero di prova
      # avanza (beta.1 → beta.2): quello vecchio è già pubblicato e verrebbe rifiutato. Il numero
      # definitivo resta: l'intestazione delle novità sul codice già unito lo usa, e `landed_at` lo dice a
      # Releases::Assign, che altrimenti lo rinumererebbe se un rilascio più alto fosse già stato unito.
      def release_numbers!(landed_at)
        Agents::ReleaseAssignment.where(workflow: @workflow, execution_phase: "closer_production").destroy_all

        staging = Agents::ReleaseAssignment.find_by(workflow: @workflow, execution_phase: "closer_staging")
        staging.nil? || advance_beta!(staging, staging.landed_at || landed_at)
      end

      # Lo stesso protocollo di Releases::Assign: la corsa con un'altra lavorazione che prende lo stesso
      # nome la perde l'indice unico del repository, si rilegge e si riprova una volta. In un punto di
      # salvataggio, perché il nome rifiutato non annulli tutto il rimando.
      def advance_beta!(staging, landed_at)
        attempt_number = 0
        begin
          attempt_number += 1
          version = next_beta(staging)
          ApplicationRecord.transaction(requires_new: true) { staging.update!(version:, landed_at:) }
          true
        rescue ActiveRecord::RecordNotUnique
          staging.restore_attributes
          retry if attempt_number < Agents::Releases::Assign::ATTEMPTS

          @number_taken = true
          false
        end
      end

      # Il successivo al più alto già preso per quella versione, non solo al proprio: un nome già
      # assegnato altrove violerebbe l'indice unico del repository.
      def next_beta(staging)
        base = staging.version.sub(/-beta\.\d+\z/, "")
        taken = Agents::ReleaseAssignment.where(github_repository_id: staging.github_repository_id)
                                         .where("version LIKE ?", "#{base}-beta.%").pluck(:version)
                                         .map { |version| version[/-beta\.(\d+)\z/, 1].to_i }
        "#{base}-beta.#{taken.max.to_i + 1}"
      end

      # Una prova del rilascio ancora aperta verrebbe riusata (Probes::Bind) col vecchio codice. Si
      # chiude scrivendo che l'ha chiusa una persona, come «Segna come rilasciato».
      def close_live_probes!
        @workflow.probes.live.find_each do |probe|
          probe.update!(closed_at: @now, next_check_at: nil,
                        evidence: probe.evidence.to_h.merge("closed_by" => "human", "account_id" => @actor&.id,
                                                            "at" => @now, "reason" => "sent_back_to_staging"))
        end
      end

      # La parola sul ticket torna quella della prova. Dopo il commit, come in Staging::VerifyMerge: un
      # ticket senza destinazione configurata non deve annullare un rimando già deciso.
      def project_status
        outcome = StatusProjection.call(workflow: @workflow, actor: @actor)
        return unless outcome.err?

        Rails.logger.warn("SendBackToStaging: stato non riallineato (workflow=#{@workflow.id}, " \
                          "code=#{outcome.error.code})")
      end

      def not_stopped
        Result.err(AppError.new("La lavorazione non è ferma in produzione",
                                code: "R409-WORKFLOW-017", status: :conflict))
      end

      def number_taken
        Result.err(AppError.new("Il numero di versione è stato assegnato a un'altra lavorazione",
                                code: "R409-WORKFLOW-009", status: :conflict))
      end
    end
  end
end
