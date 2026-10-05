# frozen_string_literal: true

module Agents
  module Workflows
    # Rework host-first (CYAU-83, expand-only): denormalizza su agents_workflows CHI (host + service
    # account) ha eseguito ciascuna fase, accanto ai vecchi *_by_agent_id (che restano). La fonte è
    # l'audit immutabile Agents::Attempt: per ogni workflow e fase si prende l'ULTIMO tentativo per
    # created_at (tie-break id) — deterministico anche con più tentativi (retry). Fase assente → colonna
    # invariata (parte NULL → resta NULL). SQL puro: nessun callback/validazione, idempotente e re-run
    # safe. La SCRITTURA a runtime resta nel claim (CYAU-82); qui si popola solo lo storico.
    #
    # Backfill ONE-SHOT da lanciare POST-DEPLOY (convenzione repo, cfr Uptime::BackfillJob): la migration
    # aggiunge solo le colonne e NON invoca questo service (una migration deve restare autocontenuta).
    #   bin/rails runner 'Agents::Workflows::BackfillHostAttribution.call'
    class BackfillHostAttribution
      # prefisso colonna workflow → valore Attempt#phase (execution_phase = Command#workflow_type).
      # NB "planned" (colonna) ↔ "planner" (fase): l'unica asimmetria di naming.
      PHASE_COLUMNS = {
        "triage" => "triage",
        "planned" => "planner",
        "autopilot" => "autopilot",
        "closer_staging" => "closer_staging",
        "closer_production" => "closer_production"
      }.freeze

      def self.call = new.call

      def call
        PHASE_COLUMNS.each { |column_prefix, attempt_phase| backfill(column_prefix, attempt_phase) }
      end

      private

      def backfill(column_prefix, attempt_phase)
        connection.execute(<<~SQL.squish)
          UPDATE agents_workflows w
          SET #{column_prefix}_by_host_id = a.host_id,
              #{column_prefix}_by_service_account_id = a.service_account_id
          FROM (
            SELECT DISTINCT ON (workflow_id) workflow_id, host_id, service_account_id
            FROM agents_attempts
            WHERE phase = #{connection.quote(attempt_phase)}
            ORDER BY workflow_id, created_at DESC, id DESC
          ) a
          WHERE a.workflow_id = w.id
        SQL
      end

      def connection = ActiveRecord::Base.connection
    end
  end
end
