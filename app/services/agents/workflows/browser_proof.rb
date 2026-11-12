# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1302 — a plan may say that a done criterion is proven in a browser (CYRA-1298). Until an agent
    # runs that proof on staging (CYAU-329), a person does: where the project asks for it, such a plan waits
    # for the go-ahead before production, like a project that asks for it on every release (CYRA-1278).
    #
    # The plan read is the latest approved one. Like ProductionHold, the predicate is SQL for the queue and
    # Ruby for the claim.
    module BrowserProof
      KIND = "browser"
      CRITERION = [ { "verification" => { "kind" => KIND } } ].to_json.freeze

      def self.owed?(workflow)
        workflow.ticket.project.browser_proof_go_ahead? && declared?(workflow)
      end

      def self.declared?(workflow)
        plan = workflow.plans.where.not(approved_at: nil).reorder(version: :desc).first
        Array(plan&.definition_of_done).any? { |criterion| criterion.is_a?(Hash) && criterion.dig("verification", "kind") == KIND }
      end

      # True for the outer agents_workflows row whose latest approved plan declares a browser proof.
      def self.declared_sql
        criterion = ActiveRecord::Base.connection.quote(CRITERION)
        <<~SQL.squish
          EXISTS (
            SELECT 1 FROM agents_plans browser_plans
            WHERE browser_plans.workflow_id = agents_workflows.id
              AND browser_plans.version = (
                SELECT MAX(approved_plans.version) FROM agents_plans approved_plans
                WHERE approved_plans.workflow_id = agents_workflows.id AND approved_plans.approved_at IS NOT NULL
              )
              AND browser_plans.definition_of_done @> #{criterion}::jsonb
          )
        SQL
      end
    end
  end
end
