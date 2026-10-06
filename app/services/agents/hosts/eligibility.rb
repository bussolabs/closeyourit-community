# frozen_string_literal: true

module Agents
  module Hosts
    # CYAU-91 — Eleggibilità host+phase: input autoritativi = host + project + phase. L'autorità è l'HOST
    # (revocato/heartbeat/certificato/capacità/repository) e la sua visibilità sul progetto (ProjectScope
    # host-only). Il runtime ammesso viene dal PhaseProfile della fase (non più da Command#allowed_runtimes).
    # Nessun Agent/Command/target. Fail-closed su fase sconosciuta.
    class Eligibility < ApplicationService
      # Capacità STABILE di un host per (progetto, fase), senza il momento: org, revoca, certificazione,
      # repo GitHub, scope, host-map e runtime dichiarato. Esclude heartbeat e slot liberi, che sono
      # liveness e capienza istantanee. Fonte unica per chi deve chiedersi «questa macchina POTREBBE
      # servire questa fase?» invece di «può servirla adesso?» — es. Ticketing::ApproveReview, che decide
      # se accodare i closer e non deve cambiare la destinazione di un ticket perché un Mac è spento da
      # cinque minuti (CYAU-100).
      def self.capable?(host:, project:, phase:)
        new(host:, project:, phase:).capable?
      end

      def initialize(host:, project:, phase:, now: Time.current)
        @host = host
        @project = project
        @phase = phase.to_s
        @now = now
      end

      def call
        return denied unless capable?
        return denied unless @host.heartbeat_online?(now: @now)
        return denied unless @host.running < @host.slots

        Result.ok(true)
      end

      def capable?
        profile = Agents::PhaseProfile.for(@phase)
        return false unless profile
        return false unless @host.supported_platform?
        return false unless same_organization? && !@host.revoked? && @host.certified?
        return false unless Github::Repository.exists?(project_id: @project.id)
        return false unless Agents::Hosts::ProjectScope.new(host: @host).allows?(@project)

        return false unless @host.repositories.include?(@project.key) && runtime_available?(profile)

        !profile.write_access? || automator_recent_enough?
      end

      # CYAU-178 — versione minima dell'automator per le fasi che SCRIVONO codice: da qui in avanti la
      # consegna deve portare l'impronta del codice che l'host aveva in mano, e un host più vecchio non
      # sa comporla. Meglio che il ticket aspetti una macchina aggiornata piuttosto che una macchina
      # lavori un'ora e si veda rifiutare la consegna alla fine.
      #
      # Le fasi che leggono soltanto restano aperte a tutti: non consegnano codice e l'impronta non la
      # devono portare, quindi escluderle sarebbe fermare lavoro che funziona benissimo.
      MIN_WRITE_VERSION = Gem::Version.new("0.26.0")

      private

      # Versione assente o non interpretabile = non idonea. NULL è il valore di un host che non l'ha mai
      # dichiarata, e dedurre «sarà aggiornato» dal silenzio è esattamente il modo in cui il difetto
      # tornerebbe dentro.
      def automator_recent_enough?
        raw = @host.automator_version.to_s
        return false if raw.blank?

        Gem::Version.new(raw) >= MIN_WRITE_VERSION
      rescue ArgumentError
        false
      end

      def same_organization?
        @host.organization_id.present? && @host.organization_id == @project&.organization_id
      end

      # CYRA-921 — the machine's work engine, not the phase default, must be installed.
      # CYAU-228 — a review-only engine too: an automator that cannot run it would only see its work rejected.
      def runtime_available?(_profile)
        required = [ @host.effective_work_engine ]
        required << @host.effective_reviewer if Agents::Host::REVIEW_ONLY_ENGINES.include?(@host.effective_reviewer)
        required.all? { |engine| runtime_present?(engine) } && opencode_ready?
      end

      # CYAU-228 — OpenCode reviews with the organization's OpenRouter model and key: without either the
      # review cannot run, so the machine waits instead of working a ticket it cannot deliver.
      def opencode_ready?
        return true unless @host.effective_reviewer == "opencode"

        organization = @host.organization
        Agents::AutomatorSetting.for(organization).opencode_model.present? && organization.openrouter_credential.present?
      end

      def runtime_present?(engine)
        @host.runtimes.any? { |runtime| runtime.is_a?(Hash) && runtime["present"] == true && runtime["name"] == engine }
      end

      def denied
        Result.err(AppError.new("Host non eleggibile", code: "R403-AGENT-006", status: :forbidden))
      end
    end
  end
end
