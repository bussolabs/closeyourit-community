# frozen_string_literal: true

module Agents
  module Probes
    # CYRA-624 — aggancia la prova, una volta sola, nell'istante in cui la macchina consegna.
    #
    # Quello che si andrà a cercare si congela QUI, prima che il rilascio parta: la versione assegnata
    # dal server (CYRA-621) e il codice sigillato al momento dell'approvazione. Ricavarli dopo
    # dall'etichetta osservata vorrebbe dire chiedere alla cosa osservata se se stessa è giusta — la
    # stessa promessa dichiarata e non mantenuta che questo lavoro toglie di mezzo.
    class Bind < ApplicationService
      def initialize(workflow:, now: Time.current)
        @workflow = workflow
        @now = now
      end

      def call
        existing = @workflow.probes.live.first
        return Result.ok(existing) if existing

        probe = @workflow.frozen_plan&.completion_probe
        kind = probe && probe["kind"]
        # Un progetto che non dichiara come si prova che un rilascio è vivo non deve far aspettare
        # un'ora per niente: si dice subito, e si dice con parole diverse da quelle della scadenza.
        return Result.err(missing_probe) unless Agents::WorkflowProbe::OBSERVABLE_KINDS.include?(kind)

        version = assigned_version
        return Result.err(missing_probe) if version.blank? || sealed_sha.blank?

        # CYRA-625 — lo scaffale delle immagini si legge solo con una credenziale di sola lettura,
        # e oggi ne esiste una sola: quella che SCRIVE, la stessa con cui tutta la flotta pubblica.
        # Quella nel server non entra. Finché non ce n'è una di lettura, la prova non si arma: si
        # dice subito, invece di aspettare un'ora in silenzio o di scrivere «Fatto» senza aver visto
        # niente.
        return Result.err(missing_credential) if probe["registry"] == "docker"

        Result.ok(@workflow.probes.create!(
                    kind: kind, bound_at: @now, next_check_at: @now,
                    expected: {
                      "version" => version, "sha" => sealed_sha,
                      "repo" => probe["repo"], "environment_id" => probe["environment_id"],
                      "registry" => probe["registry"], "package" => probe["package"]
                    }.compact
                  ))
      end

      private

      # Il numero deciso dal server prima che la fase partisse, non quello che la macchina dichiara di
      # aver pubblicato: è il confronto che rende la prova una prova.
      def assigned_version
        Agents::ReleaseAssignment.find_by(workflow: @workflow, execution_phase: "closer_production")&.version
      end

      def sealed_sha
        Agents::ReleaseAssignment.find_by(workflow: @workflow, execution_phase: "closer_production")&.sha
      end

      def missing_probe
        AppError.new("Il progetto non dichiara come si prova che un rilascio è vivo",
                     code: "R409-WORKFLOW-011", status: :conflict)
      end

      # Distinguibile dagli altri due motivi: si sistema in un posto diverso — non configurando il
      # progetto e non aspettando, ma collegando una credenziale che non esiste ancora.
      def missing_credential
        AppError.new("Manca la credenziale di sola lettura per il registro delle immagini",
                     code: "R409-WORKFLOW-012", status: :conflict)
      end
    end
  end
end
