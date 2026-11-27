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
      # CYRA-1294 — the trial release runs the whole suite before it deploys: it is looked at less often, and
      # past this window from the delivery a person is called.
      DEPLOY_RETRY_EVERY = 3.minutes
      DEPLOY_GRACE_WINDOW = 90.minutes
      # CYRA-1366 — a trial release that failed or never came is told as such, not as a proposal check.
      DEPLOY_STOP_KIND = "staging_deploy"
      DEPLOY_STOP_CODES = %w[staging_run_failed staging_not_deployed].freeze

      # Which trial-release stop it is, for the sentence: it failed (or was cancelled), or it never came.
      def self.deploy_stop_key(workflow)
        workflow.blocked_reason.to_s.end_with?("staging_not_deployed") ? "missing" : "failed"
      end

      # The commit the closer declares it prepared. It sits in the attempt's result, an immutable audit:
      # it is never taken from the branch, which moves.
      def self.declared_commit(workflow)
        workflow.attempts.where(phase: "closer_staging")
                .where("result ->> 'state' = ?", "staging-released")
                .order(created_at: :desc)
                .pick(Arel.sql("result ->> 'commit'"))
      end

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

        landed?(candidate, declared) ? after_merge(candidate, declared) : not_yet(candidate)
      rescue Github::Client::Error => e
        e.transient? ? retry_later(e.code) : escalate_to_human("staging_unreadable")
      end

      private

      def client = @client ||= Github::Client.new

      def declared_commit = self.class.declared_commit(@workflow)

      def landed?(candidate, declared)
        installation = candidate.repository&.github_installation_id
        return false if installation.blank?

        base = candidate.base_ref.presence || "main"
        client.commit_contained?(installation, candidate.repository_full_name, base, declared) &&
          client.commit_contained?(installation, candidate.repository_full_name, declared, candidate.head_sha)
      end

      # CYRA-1294 — where the project asks for it, the merge is not enough: the trial release must have gone
      # through. A failed one calls a person at once; one that never shows up, past the window.
      # CYRA-1366 — with the rule off the merge is enough, and the trial release is watched until production.
      def after_merge(candidate, declared)
        return verified!(watch_deploy: candidate.repository.present?) unless deploy_proof_required?(candidate)

        case DeployRun.outcome(client:, installation: candidate.repository.github_installation_id,
                               repository: candidate.repository_full_name, commit: declared)
        when DeployRun::RELEASED then verified!
        when DeployRun::FAILED then escalate_to_human("staging_run_failed")
        else deploy_overdue? ? escalate_to_human("staging_not_deployed") : retry_later("staging_run_pending", every: DEPLOY_RETRY_EVERY)
        end
      end

      # CYRA-1366 — every piece of work goes to production (CYRA-1193), whatever its proof of done: all wait.
      def deploy_proof_required?(candidate)
        @workflow.ticket.project.staging_deploy_proof? && candidate.repository.present?
      end

      def deploy_overdue? = @workflow.closer_staging_completed_at < @now - DEPLOY_GRACE_WINDOW

      # `watch_deploy`: the next check belongs to Agents::Staging::WatchDeploy, until production starts.
      def verified!(watch_deploy: false)
        @workflow.update!(closer_staging_verified_at: @now, closer_staging_last_error_code: nil,
                          closer_staging_next_check_at: (@now + DEPLOY_RETRY_EVERY if watch_deploy))
        # CYRA-1050 — a missing review status does not stop the release: the merge was seen anyway.
        # CYRA-1193 — production always follows, even when the merge is the proof of done: a beta tag
        # is not a release, and closing the work here left the stable release undone.
        Agents::Workflows::StatusProjection.call(workflow: @workflow)
        # CYRA-1278 — where the project asks for it, production now waits for a person.
        Agents::Workflows::RequestProductionApproval.call(workflow: @workflow)
        Result.ok(@workflow)
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
      def retry_later(code, every: RETRY_EVERY)
        @workflow.update!(closer_staging_next_check_at: @now + every,
                          closer_staging_last_error_code: code,
                          closer_staging_checks_count: @workflow.closer_staging_checks_count + 1)
        Result.ok(@workflow)
      end

      def escalate_to_human(code)
        @workflow.update!(closer_staging_next_check_at: nil, closer_staging_last_error_code: code)
        Agents::Workflows::BlockExhaustedPhase.call(
          workflow: @workflow, phase: "closer_staging", source: "staging_proof", reason: code,
          kind: DEPLOY_STOP_CODES.include?(code) ? DEPLOY_STOP_KIND : "candidate_check"
        )
        Result.ok(@workflow)
      end
    end
  end
end
