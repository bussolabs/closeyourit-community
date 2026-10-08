# frozen_string_literal: true

module Agents
  module Hosts
    # Valida e persiste lo snapshot non sensibile inviato dall'Automator sul check-in cron. Il lookup
    # parte sempre dall'organizzazione del progetto (anti-BOLA); una allowlist ricostruisce i jsonb e
    # scarta campi sconosciuti/sensibili. Il lock impedisce a richieste riordinate di sovrascrivere lo
    # snapshot più recente.
    class RecordHeartbeat < ApplicationService
      MAX_RUNTIMES = 32
      MAX_REPOSITORIES = 100
      MAX_ACTIVE_RUNS = 100
      MAX_STRING_LENGTH = 200
      MAX_RUN_ID_LENGTH = 128
      MAX_INTERVAL_MINUTES = 2_147_483_647
      RUN_PHASES = %w[validating ready implementing verifying reviewing waiting blocked in_review completed].freeze
      LEASE_HEALTHS = %w[active expired unknown].freeze
      # CYRA-999 — the Automator sends its last 5 stops; an overlong reason is shortened, never rejected,
      # because a rejected heartbeat would turn the machine offline.
      MAX_LAST_STOPS = 5
      MAX_STOP_REASON_LENGTH = 500
      STOP_STATES = %w[waiting blocked].freeze

      def initialize(project:, payload:, at: Time.current)
        @project = project
        @payload = payload.to_h.deep_stringify_keys
        @at = at
        @errors = {}
      end

      def call
        host = @project.organization.agent_hosts.active.find_by!(id: @payload["host_id"])
        return unsupported_host_result unless host.supported_platform?

        after_host_resolved(host)
        attributes = normalized_attributes
        return invalid_result if @errors.any?

        authorized = false
        updated = false
        host.with_lock do
          # Il lookup active precedente può essere diventato stantio mentre aspettavamo il lock.
          next if host.revoked? || !authorized_heartbeat_project?(host)

          authorized = true

          # `at` viene acquisito all'inizio della request: chi ottiene il lock per ultimo non è
          # necessariamente il battito più nuovo. Un retry vecchio è quindi un successo no-op.
          if newer_than_snapshot?(host)
            host.update!(attributes.merge(last_heartbeat_at: @at, heartbeat_project: @project))
            updated = true
          end
        end
        return not_found_result unless authorized

        # CYRA-823 — chi ha la scheda di questa macchina aperta la vede cambiare senza ricaricarla.
        # Fuori dal lock e solo se lo snapshot è cambiato davvero: un battito vecchio arrivato in
        # ritardo non ha niente da annunciare. Il segnale è coalescato (Realtime::ThrottledRefresh),
        # quindi una flotta che batte spesso non si traduce in una richiesta per battito.
        ::Agents::Hosts::Broadcast.activity(host) if updated

        Result.ok(host)
      rescue ActiveRecord::RecordNotFound
        not_found_result
      rescue ActiveRecord::RecordInvalid => e
        Result.err(
          AppError.new(e.message, code: "R422-AGENT-004", status: :unprocessable_content,
                                  details: e.record.errors.as_json)
        )
      end

      private

      # Un host usa un solo canale heartbeat di progetto. Il primo battito crea il binding; i token
      # ingest di altri progetti della stessa organizzazione ricevono lo stesso 404 anti-BOLA.
      def authorized_heartbeat_project?(host)
        host.heartbeat_project_id.nil? || host.heartbeat_project_id == @project.id
      end

      # Hook no-op per orchestrare deterministicamente i test di concorrenza tra lookup e lock.
      def after_host_resolved(_host); end

      def normalized_attributes
        attributes = {}
        copy_string(attributes, "automator_version", allow_nil: true)
        copy_platform(attributes)
        copy_string(attributes, "arch")
        copy_integer(attributes, "running", minimum: 0, maximum: MAX_ACTIVE_RUNS)
        copy_integer(attributes, "slots", minimum: 1, maximum: MAX_ACTIVE_RUNS)
        copy_enum(attributes, "host_status", Agents::Host::HOST_STATUSES)
        copy_integer(attributes, "heartbeat_expected_interval_minutes", source: "expected_interval_minutes",
                     minimum: 1, maximum: MAX_INTERVAL_MINUTES)
        copy_integer(attributes, "heartbeat_grace_minutes", source: "grace_minutes",
                     minimum: 0, maximum: MAX_INTERVAL_MINUTES)
        attributes[:runtimes] = normalize_runtimes if @payload.key?("runtimes")
        attributes[:repositories] = normalize_repositories if @payload.key?("repositories")
        attributes[:active_runs] = normalize_active_runs if @payload.key?("active_runs")
        attributes[:last_stops] = normalize_last_stops if @payload.key?("last_stops")
        attributes
      end

      def copy_string(attributes, target, source: target, allow_nil: false)
        return unless @payload.key?(source)

        value = @payload[source]
        if allow_nil && value.nil?
          attributes[target.to_sym] = nil
        elsif valid_string?(value)
          attributes[target.to_sym] = value
        else
          add_error(source)
        end
      end

      def copy_platform(attributes)
        return unless @payload.key?("platform")

        value = @payload["platform"]
        value == Agents::Host::SUPPORTED_PLATFORM ? attributes[:platform] = value : add_error("platform")
      end

      def copy_integer(attributes, target, source: target, minimum:, maximum:)
        return unless @payload.key?(source)

        value = strict_integer(@payload[source])
        if value&.between?(minimum, maximum)
          attributes[target.to_sym] = value
        else
          add_error(source)
        end
      end

      def copy_enum(attributes, key, values)
        return unless @payload.key?(key)

        value = @payload[key]
        values.include?(value) ? attributes[key.to_sym] = value : add_error(key)
      end

      def normalize_runtimes
        list = bounded_array("runtimes", MAX_RUNTIMES)
        return [] unless list

        list.filter_map.with_index do |runtime, index|
          next add_error("runtimes.#{index}") unless runtime.is_a?(Hash)

          value = runtime.deep_stringify_keys
          unless valid_string?(value["name"]) && boolean?(value["present"]) &&
                 nullable_string?(value["version"]) && boolean?(value["required"])
            next add_error("runtimes.#{index}")
          end
          value.slice("name", "present", "version", "required")
        end
      end

      def normalize_repositories
        list = bounded_array("repositories", MAX_REPOSITORIES)
        return [] unless list

        normalized = list.filter_map.with_index do |repository, index|
          if repository.is_a?(String) && repository.match?(/\A[A-Z0-9]{1,4}\z/)
            repository
          else
            add_error("repositories.#{index}")
          end
        end
        return normalized if @errors.any? { |key, _| key.start_with?("repositories") }

        within_organization(normalized)
      end

      # Project keys are declared capabilities, not authority: only those of this organization are kept.
      # Unknown keys are dropped, not rejected: a deleted project must not silence the host (CYRA-1056).
      def within_organization(repositories)
        return repositories if repositories.empty?

        known = @project.organization.projects.where(key: repositories.uniq).pluck(:key).to_set
        repositories.select { |key| known.include?(key) }
      end

      def normalize_active_runs
        list = bounded_array("active_runs", MAX_ACTIVE_RUNS)
        return [] unless list

        list.filter_map.with_index do |run, index|
          next add_error("active_runs.#{index}") unless run.is_a?(Hash)

          value = run.deep_stringify_keys
          unless valid_active_run?(value)
            next add_error("active_runs.#{index}")
          end
          value.slice(
            "ticket", "run_id", "phase", "runtime", "started_at", "updated_at",
            "lease_expires_at", "lease_health", "stalled"
          )
        end
      end

      def normalize_last_stops
        list = bounded_array("last_stops", MAX_LAST_STOPS)
        return [] unless list

        list.filter_map.with_index do |stop, index|
          next add_error("last_stops.#{index}") unless stop.is_a?(Hash)

          value = stop.deep_stringify_keys
          reason = value["reason"]
          unless valid_string?(value["action"]) && STOP_STATES.include?(value["state"]) &&
                 reason.is_a?(String) && reason.present? && !reason.include?("\0")
            next add_error("last_stops.#{index}")
          end
          { "action" => value["action"], "state" => value["state"], "reason" => reason.first(MAX_STOP_REASON_LENGTH) }
        end
      end

      def valid_active_run?(run)
        valid_string?(run["ticket"]) && run["run_id"].is_a?(String) && run["run_id"].present? &&
          run["run_id"].length <= MAX_RUN_ID_LENGTH && nullable_enum?(run["phase"], RUN_PHASES) &&
          nullable_string?(run["runtime"]) && valid_timestamp?(run["started_at"]) &&
          valid_timestamp?(run["updated_at"]) && valid_timestamp?(run["lease_expires_at"]) &&
          LEASE_HEALTHS.include?(run["lease_health"]) && boolean?(run["stalled"])
      end

      def bounded_array(key, maximum)
        value = @payload[key]
        return value if value.is_a?(Array) && value.length <= maximum

        add_error(key)
        nil
      end

      def valid_string?(value)
        value.is_a?(String) && value.present? && value.length <= MAX_STRING_LENGTH && !value.include?("\0")
      end

      def nullable_string?(value)
        value.nil? || valid_string?(value)
      end

      def nullable_enum?(value, values)
        value.nil? || values.include?(value)
      end

      def valid_timestamp?(value)
        return true if value.nil?
        return false unless value.is_a?(String) && value.length <= MAX_STRING_LENGTH

        Time.iso8601(value)
        true
      rescue ArgumentError
        false
      end

      def boolean?(value) = value == true || value == false

      def strict_integer(value)
        return value if value.is_a?(Integer)
        return Integer(value, exception: false) if value.is_a?(String) && value.match?(/\A\d+\z/)

        nil
      end

      def newer_than_snapshot?(host)
        host.last_heartbeat_at.nil? || @at >= host.last_heartbeat_at
      end

      def add_error(key)
        @errors[key] = [ "non valido" ]
        nil
      end

      def invalid_result
        Result.err(
          AppError.new("Telemetria host non valida", code: "R422-AGENT-004", status: :unprocessable_content,
                                                        details: @errors)
        )
      end

      def not_found_result
        Result.err(
          AppError.new("Host automator non trovato", code: "R404-AGENT-003", status: :not_found)
        )
      end

      def unsupported_host_result
        Result.err(
          AppError.new("Host automator non supportato: è richiesto Linux", code: "R403-AGENT-007", status: :forbidden)
        )
      end
    end
  end
end
