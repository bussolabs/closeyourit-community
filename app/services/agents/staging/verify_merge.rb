# frozen_string_literal: true

module Agents
  module Staging
    # CYRA-620 — la prova che il codice approvato è DAVVERO atterrato sulla linea principale.
    #
    # Finora il lavoro andava avanti perché la macchina scriveva «fatto». Se l'ultimo passaggio non
    # riusciva — spedizione rifiutata, connessione caduta, copia di lavoro vecchia — nessuno se ne
    # accorgeva: il passo dopo partiva lo stesso, e in produzione poteva uscire un codice diverso da
    # quello approvato, o nessuno.
    #
    # Due domande, e servono tutte e due:
    #   1. il commit che la macchina dichiara di aver preparato è dentro il ramo principale?
    #   2. quel commit contiene il codice che una persona ha approvato?
    #
    # La seconda non è una ripetizione della prima: senza, una macchina che lavora su una copia
    # vecchia può spingere qualcosa che atterra benissimo e non è ciò che hai guardato.
    class VerifyMerge < ApplicationService
      # Ogni quanto tornare a guardare, e per quanto insistere prima di chiamare una persona. Il
      # ritardo fra la spedizione e la sua visibilità si misura in secondi, non in minuti: oltre la
      # grazia non è più «non ancora», è «non è arrivato».
      RETRY_EVERY = 1.minute
      GRACE_WINDOW = 15.minutes

      def initialize(workflow:, client: nil, now: Time.current)
        @workflow = workflow
        @client = client
        @now = now
      end

      def call
        return Result.ok(@workflow) if @workflow.closer_staging_verified_at?
        return Result.ok(@workflow) unless @workflow.closer_staging_completed_at?

        candidate = @workflow.review_candidate
        declared = declared_commit
        return escalate_to_human("staging_evidence_missing") if candidate.nil? || declared.blank?

        landed?(candidate, declared) ? verified! : not_yet(candidate)
      rescue Github::Client::Error => e
        e.transient? ? retry_later(e.code) : escalate_to_human("staging_unreadable")
      end

      private

      def client = @client ||= Github::Client.new

      # Il commit che il closer dichiara di aver preparato. Sta nel result del tentativo, che è audit
      # immutabile: non si prende dal ramo, che si muove.
      def declared_commit
        @workflow.attempts.where(phase: "closer_staging")
                 .where("result ->> 'state' = ?", "staging-released")
                 .order(created_at: :desc)
                 .pick(Arel.sql("result ->> 'commit'"))
      end

      def landed?(candidate, declared)
        installation = candidate.repository&.github_installation_id
        return false if installation.blank?

        base = candidate.base_ref.presence || "main"
        client.commit_contained?(installation, candidate.repository_full_name, base, declared) &&
          client.commit_contained?(installation, candidate.repository_full_name, declared, candidate.head_sha)
      end

      def verified!
        @workflow.update!(closer_staging_verified_at: @now, closer_staging_next_check_at: nil,
                          closer_staging_last_error_code: nil)
        # CYRA-1050 — a missing review status does not stop the release: the merge was seen anyway.
        merge_is_the_proof? ? complete_on_merge! : Agents::Workflows::StatusProjection.call(workflow: @workflow)
        Result.ok(@workflow)
      end

      # When the project's proof of done is the merge, this verified merge IS that proof: production
      # has nothing to observe and refused to bind it, so the work never became done.
      def merge_is_the_proof?
        @workflow.frozen_plan&.completion_probe&.dig("kind") == "merge"
      end

      # Same writes as a closed production probe, together: a done ticket on unfinished work, or the
      # reverse, would never be looked at again. The prerequisites gate in ChangeStatus has the last
      # word: if it refuses, nothing is written and the work waits in production as before.
      def complete_on_merge!
        state = @workflow.organization.ticket_statuses.active.category_done.ordered.first
        return if state.nil?

        ActiveRecord::Base.transaction do
          @workflow.update!(completed_at: @now)
          outcome = Ticketing::ChangeStatus.call(organization: @workflow.organization, ticket: @workflow.ticket,
                                               status_id: state.id, channel: :workflow)
          raise ActiveRecord::Rollback unless outcome.ok?
        end
      end

      # «Non ancora» finché la finestra di grazia dalla consegna non è passata: fra la spedizione e la
      # sua visibilità passano secondi, e chiamare una persona in quei secondi la chiamerebbe per
      # niente. Oltre, non è più «non ancora».
      def not_yet(_candidate)
        return escalate_to_human("staging_not_merged") if past_grace?

        retry_later("not_merged_yet")
      end

      def past_grace?
        @workflow.closer_staging_completed_at < @now - GRACE_WINDOW
      end

      # Il servizio non risponde: si aspetta e si riprova da soli. Non si chiede niente a nessuno e la
      # lavorazione non risulta ferma — «non ho potuto guardare» non è «non è arrivato».
      def retry_later(code)
        @workflow.update!(closer_staging_next_check_at: @now + RETRY_EVERY,
                          closer_staging_last_error_code: code,
                          closer_staging_checks_count: @workflow.closer_staging_checks_count + 1)
        Result.ok(@workflow)
      end

      def escalate_to_human(code)
        @workflow.update!(closer_staging_next_check_at: nil, closer_staging_last_error_code: code)
        Agents::Workflows::BlockExhaustedPhase.call(
          workflow: @workflow, phase: "closer_staging", source: "staging_proof", reason: code
        )
        Result.ok(@workflow)
      end
    end
  end
end
