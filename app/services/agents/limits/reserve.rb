# frozen_string_literal: true

module Agents
  module Limits
    # Gate server-side per nuove partenze. Le policy applicabili sono bloccate in ordine stabile e i
    # contatori sono aggiornati nella stessa transazione della decisione persistita.
    class Reserve < ApplicationService
      Decision = Data.define(:reservation, :replayed)

      def initialize(organization:, host:, project:, phase:, idempotency_key:, estimated_cost: nil)
        @organization = organization
        @host = host
        @project = project
        @phase = phase.to_s
        @profile = Agents::PhaseProfile.for(@phase)
        # CYRA-921 — limits per engine count the engine that really does the work.
        @runtime = @profile && host.effective_work_engine
        @idempotency_key = idempotency_key.to_s.strip
        @ttl_seconds = @profile&.ttl
        @estimated_cost_supplied = !estimated_cost.nil?
        @estimated_cost = Agents::Limits::Cost.parse(estimated_cost)
      end

      def call
        candidate = build_reservation
        return invalid_cost(candidate) if @estimated_cost_supplied && @estimated_cost.nil?
        return invalid_scope(candidate) unless @profile
        return invalid_scope(candidate) unless authoritative_scope?

        ensure_default_policy!

        Agents::LimitPolicy.transaction do
          policies = Agents::LimitPolicy.applicable_to(
            organization: @organization, project: @project, runtime: @runtime
          ).order(:id).lock.to_a
          after_policies_locked
          return invalid_scope(candidate) unless lock_active_host
          return invalid_scope(candidate) unless lock_active_project
          lock_host_visibility
          return invalid_scope(candidate) unless host_sees_project?

          refresh_decision_time(candidate)

          existing = Agents::LimitReservation.find_by(organization: @organization, idempotency_key: @idempotency_key)
          return replay(existing) if existing
          return invalid(candidate) unless candidate.valid?

          usages = usages_for(policies)
          reason = denial_reason(policies, usages)
          reservation = persist_decision!(candidate, reason)
          increment!(usages) if reservation.granted?
          Result.ok(Decision.new(reservation:, replayed: false))
        end
      rescue ActiveRecord::RecordInvalid => e
        invalid(e.record)
      rescue ActiveRecord::InvalidForeignKey
        invalid_scope(candidate)
      end

      private

      # Punto di sincronizzazione intenzionale per le spec PG: i test dimostrano che il secondo host
      # non entra nella sezione critica finché il primo detiene il lock.
      def after_policies_locked = nil

      def ensure_default_policy!
        scope = Agents::LimitPolicy.where(organization: @organization, project: nil, runtime: nil)
        return if scope.exists?

        # L'indice unique NULLS NOT DISTINCT rende atomico il bootstrap concorrente senza bloccare
        # la riga organization per tutta la transazione esterna di Claim. insert_all usa ON CONFLICT
        # e non viene anticipato dalla validazione Rails di unicità; il precedente organization.with_lock
        # invertiva l'ordine con i lease legacy, che trattengono host/ticket mentre verificano le FK.
        Agents::LimitPolicy.insert_all(
          [ { organization_id: @organization.id, project_id: nil, runtime: nil } ],
          unique_by: "index_agents_limit_policies_scope"
        )
      end

      def build_reservation
        Agents::LimitReservation.new(
          organization: @organization, host: @host, project: @project, runtime: @runtime, phase: @phase,
          idempotency_key: @idempotency_key, requested_ttl_seconds: @ttl_seconds,
          estimated_cost: @estimated_cost, outcome: "granted",
          expires_at: nil
        )
      end

      # Il clock va letto dopo tutti i lock potenzialmente bloccanti: scadenza, periodo giornaliero e
      # max_parallel descrivono l'istante effettivo della decisione, condiviso da ogni nodo Rails.
      def refresh_decision_time(candidate)
        @now = Agents::Limits::Clock.current
        candidate.expires_at = @now + @ttl_seconds.seconds if @ttl_seconds
      end

      def replay(existing)
        return conflict unless same_request?(existing)

        Result.ok(Decision.new(reservation: existing, replayed: true))
      end

      # La fase fa parte dell'identità della richiesta (colonna dedicata, finding Codex P2): due fasi con lo
      # stesso runtime/TTL sotto la stessa idempotency key sono richieste diverse → conflict, non replay.
      # Le reservation legacy (phase NULL, create prima di CYAU-91) restano replayabili: preservano la
      # garanzia di idempotenza durante il rollout (nessun falso conflict su un retry identico).
      def same_request?(reservation)
        reservation.host_id == @host.id && reservation.project_id == @project&.id &&
          (reservation.phase.nil? || reservation.phase == @phase) &&
          reservation.runtime == @runtime && reservation.requested_ttl_seconds == @ttl_seconds &&
          reservation.estimated_cost == @estimated_cost
      end

      def usages_for(policies)
        period_on = @now.utc.to_date
        existing = Agents::LimitUsage.where(policy: policies, period_on:).index_by(&:policy_id)
        policies.to_h do |policy|
          usage = existing[policy.id] || Agents::LimitUsage.create!(policy:, period_on:)
          [ policy, usage ]
        end
      end

      def denial_reason(policies, usages)
        return "kill_switch" if policies.any?(&:stop_dispatch?)
        return "max_runtime" if policies.any? do |policy|
          policy.max_runtime_seconds && @ttl_seconds > policy.max_runtime_seconds
        end
        return "max_parallel" if policies.any? { |policy| parallel_exhausted?(policy) }
        return "max_daily_runs" if policies.any? do |policy|
          policy.max_daily_runs && usages.fetch(policy).runs >= policy.max_daily_runs
        end
        return "estimated_cost_unavailable" if @estimated_cost.nil? && policies.any?(&:max_daily_cost)
        return "max_daily_cost" if policies.any? { |policy| cost_exhausted?(policy, usages.fetch(policy)) }

        nil
      end

      def parallel_exhausted?(policy)
        return false if policy.max_parallel.nil?

        scope = Agents::LimitReservation.active(@now).where(organization: @organization)
        scope = scope.where(project: policy.project) if policy.project
        scope = scope.where(runtime: policy.runtime) if policy.runtime
        scope.count >= policy.max_parallel
      end

      def cost_exhausted?(policy, usage)
        return false if @estimated_cost.nil?

        projected = usage.cost + @estimated_cost
        return true if projected > Agents::LimitPolicy::MAX_COST
        return false if policy.max_daily_cost.nil?

        usage.cost >= policy.max_daily_cost || projected > policy.max_daily_cost
      end

      def persist_decision!(candidate, reason)
        if reason
          candidate.assign_attributes(outcome: "denied", denial_reason: reason, expires_at: nil)
        end
        candidate.save!
        candidate
      end

      def increment!(usages)
        usages.each_value do |usage|
          attributes = { runs: usage.runs + 1 }
          attributes[:cost] = usage.cost + @estimated_cost if @estimated_cost
          usage.update!(attributes)
        end
      end

      def authoritative_scope?
        @host&.organization_id == @organization.id && !@host.revoked? && host_sees_project?
      end

      # Scope host-only (CYAU-91): la visibilità sul progetto è del service account dell'host (ProjectScope).
      # Verificata prima della transazione (fail-fast) e di nuovo sotto lock, dopo aver riletto l'host.
      def host_sees_project?
        Agents::Hosts::ProjectScope.new(host: @host).allows?(@project)
      end

      # Serializza la revoca concorrente della visibilità del service account dell'host (finding Codex P1):
      # lockando TUTTE le righe che ProjectScope legge — membership dirette (progetto/gruppo) E accesso via
      # team (appartenenza + team-project/team-group access) — chiudiamo la finestra tra il check ProjectScope
      # e il commit. Ordine di lock: policy → host → project → visibilità (suffisso deterministico, `order(:id)`).
      def lock_host_visibility
        service_account_id = @host.service_account_id
        return unless service_account_id

        # Membership d'org: radice della visibilità owner (VisibleScope tratta l'owner come unscoped). Lockarla
        # serializza un downgrade owner→member concorrente. Il service account host è sempre non-god (vietato).
        Connections::Membership.where(account_id: service_account_id, organization_id: @organization.id)
                               .order(:id).lock.load
        Connections::ProjectMembership.where(account_id: service_account_id, project_id: @project.id)
                                      .order(:id).lock.load
        team_ids = Connections::TeamMembership.where(account_id: service_account_id).order(:id).lock.pluck(:team_id)
        Connections::TeamProjectAccess.where(team_id: team_ids, project_id: @project.id).order(:id).lock.load if team_ids.any?

        group_id = @project.group_id
        return unless group_id

        Connections::GroupMembership.where(account_id: service_account_id, group_id:).order(:id).lock.load
        Connections::TeamGroupAccess.where(team_id: team_ids, group_id:).order(:id).lock.load if team_ids.any?
      end

      # Ordine globale del dispatch: organization → policy → host → agent → project → ticket. Il tratto
      # operativo omette intenzionalmente organization: il bootstrap della policy usa l'indice unique,
      # così Claim non serializza tutta l'organizzazione e non collide con le FK dei lease. Ogni writer
      # può prendere un suffisso della gerarchia ma non risalire: Reserve (host-first) usa policy → host → project,
      # CandidateSnapshot prosegue fino a ticket, i lease/revoke usano host → ticket e SetTargets agent → project.
      # lock! ricarica i record e rende autorevole anche la decisione di un caller stale.
      def lock_active_host
        @host.lock!
        @host.organization_id == @organization.id && !@host.revoked?
      rescue ActiveRecord::RecordNotFound
        false
      end

      def lock_active_project
        @project.lock!
        @project.organization_id == @organization.id
      rescue ActiveRecord::RecordNotFound
        false
      end

      def invalid_cost(candidate)
        candidate.errors.add(:estimated_cost, :invalid)
        invalid(candidate)
      end

      def invalid_scope(candidate)
        candidate.errors.add(:base, :invalid)
        invalid(candidate)
      end

      def invalid(record)
        Result.err(AppError.new(
          "Reservation non valida", code: "R422-AGENT-005", status: :unprocessable_content,
          details: record.errors.as_json
        ))
      end

      def conflict
        Result.err(AppError.new(
          "Idempotency key già usata con parametri diversi", code: "R409-AGENT-001", status: :conflict
        ))
      end
    end
  end
end
