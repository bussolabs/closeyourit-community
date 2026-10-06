# frozen_string_literal: true

module Agents
  module Releases
    # CYRA-621 — assegna il numero a una lavorazione, una volta sola, prima che il rilascio parta.
    #
    # Idempotente per (lavorazione, fase): un secondo claim sulla stessa fase ritrova la riga e non ne
    # fa un'altra. È quello che tiene insieme la versione di prova e quella definitiva — prima le
    # numeravano due sessioni diverse in due momenti diversi, e niente garantiva che tornassero.
    #
    # La corsa fra due lavorazioni dello stesso progetto la perde il DATABASE, non GitHub a
    # pubblicazione avvenuta: l'indice unico su (repository, versione) rifiuta il doppione, si rilegge
    # da capo e si riprova una volta. Prima leggevano lo stesso «ultimo numero» e sceglievano lo
    # stesso nome, e la seconda pubblicazione veniva respinta senza che nessuno avesse sbagliato.
    class Assign < ApplicationService
      ATTEMPTS = 2

      def initialize(workflow:, execution_phase:, client: nil)
        @workflow = workflow
        @execution_phase = execution_phase
        @client = client
      end

      def call
        return Result.ok(nil) unless Agents::ReleaseAssignment::PHASES.include?(@execution_phase)

        repository = @workflow.ticket.project.github_repository
        return Result.ok(nil) if repository.nil?

        existing = Agents::ReleaseAssignment.find_by(workflow: @workflow, execution_phase: @execution_phase)
        return Result.ok(existing) if existing

        # Sulla versione definitiva il punto da pubblicare non è negoziabile: è il commit che il
        # sistema ha VISTO atterrare. Senza, non si assegna niente e la fase non parte — pubblicare
        # «da qualche parte» è esattamente ciò che questo lavoro toglie di mezzo.
        sha = @execution_phase == "closer_production" ? verified_commit : nil
        return Result.err(missing_commit) if @execution_phase == "closer_production" && sha.blank?

        assign(repository, sha)
      end

      private

      def client = @client ||= Github::Client.new

      def assign(repository, sha)
        attempt_number = 0
        begin
          attempt_number += 1
          computed = Agents::Releases::NextVersion.call(repository:, tickets: [ @workflow.ticket ], client:)
          return computed if computed.err?

          computed = Result.ok(computed.value.merge(version: settled_version(repository, computed.value)))

          Result.ok(Agents::ReleaseAssignment.create!(
                      workflow: @workflow, github_repository: repository,
                      execution_phase: @execution_phase, version: version_number(computed.value),
                      sha:, baseline_tag: computed.value[:baseline_tag]
                    ))
        rescue ActiveRecord::RecordNotUnique
          # Un'altra lavorazione ha preso quel nome fra il calcolo e la scrittura: si rilegge e si
          # riprova. Una volta sola — se succede due volte non è più una corsa, è qualcosa da guardare.
          retry if attempt_number < ATTEMPTS

          Result.err(AppError.new("Il numero di versione è stato assegnato a un'altra lavorazione",
                                  code: "R409-WORKFLOW-009", status: :conflict))
        end
      end

      # CYRA-878 — production publishes the number its own staging release carried: the CHANGELOG heading
      # on the sealed commit is that number. Staging never reuses a number another workflow of the same
      # repository still holds: two workflows under one heading could not both reach production.
      def settled_version(repository, computed)
        return own_staging_version || computed[:version] if @execution_phase == "closer_production"

        pending = pending_versions(repository, computed[:baseline_tag])
        return computed[:version] if pending.empty? || (parse(computed[:version]) <=> pending.max) == 1

        major, minor, patch = pending.max
        fixes = parse(computed[:version])[2].positive?
        fixes ? "v#{major}.#{minor}.#{patch + 1}" : "v#{major}.#{minor + 1}.0"
      end

      def own_staging_version
        Agents::ReleaseAssignment.find_by(workflow: @workflow, execution_phase: "closer_staging")
                                 &.version&.sub(/-beta\.\d+\z/, "")
      end

      # Staging numbers of OTHER workflows of this repository that are above the last stable tag, i.e.
      # still waiting for their production release. CYRA-1031 — cancelled workflows count too: their
      # beta tag and CHANGELOG section may already be published, and cancelling takes neither back.
      def pending_versions(repository, baseline_tag)
        floor = baseline_tag ? parse(baseline_tag) : [ 0, 0, 0 ]
        Agents::ReleaseAssignment.for_phase("closer_staging")
                                 .where(github_repository: repository).where.not(workflow: @workflow)
                                 .pluck(:version)
                                 .map { |version| parse(version.sub(/-beta\.\d+\z/, "")) }
                                 .select { |version| (version <=> floor) == 1 }
      end

      def parse(version) = version.delete_prefix("v").split(".").map(&:to_i)

      # La prova porta il suffisso: è la stessa versione, provata prima di uscire. Il contatore parte
      # da quante prove di QUELLA versione sono già state assegnate, così due giri sulla stessa
      # versione non si contendono lo stesso nome.
      def version_number(computed)
        return computed[:version] if @execution_phase == "closer_production"

        already_done = Agents::ReleaseAssignment.for_phase("closer_staging")
                                             .where("version LIKE ?", "#{computed[:version]}-beta.%").count
        "#{computed[:version]}-beta.#{already_done + 1}"
      end

      # Il commit che il sistema ha visto atterrare sulla linea principale (CYRA-620): non quello che
      # la macchina dichiara, che è la cosa che si sta smettendo di credere sulla parola.
      def verified_commit
        return nil unless @workflow.closer_staging_verified_at?

        @workflow.attempts.where(phase: "closer_staging")
                 .where("result ->> 'state' = ?", "staging-released")
                 .order(created_at: :desc)
                 .pick(Arel.sql("result ->> 'commit'"))
      end

      def missing_commit
        AppError.new("Il punto di codice da pubblicare non è stato verificato",
                     code: "R409-WORKFLOW-010", status: :conflict)
      end
    end
  end
end
