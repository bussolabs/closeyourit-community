# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1302 — a plan may say that a done criterion is proven in a browser (CYRA-1298). Until an agent
    # runs that proof on staging (CYAU-329), a person does: where the project asks for it, such a plan waits
    # for the go-ahead before production, like a project that asks for it on every release (CYRA-1278).
    #
    # The plan read is the latest approved one. Like ProductionHold, the predicate is SQL for the queue and
    # Ruby for the claim.
    #
    # CYAU-329 — with the project's Tester on, the machine runs that proof before it tags production. So the
    # release goes only to a machine that declares a browser, and a person is asked only where no machine of
    # the project has one. A person's go-ahead still opens the release to any machine: they did the proof.
    module BrowserProof
      KIND = "browser"
      CRITERION = [ { "verification" => { "kind" => KIND } } ].to_json.freeze

      def self.owed?(workflow)
        project = workflow.ticket.project
        return false unless project.browser_proof_go_ahead? || tester?(project)
        return false unless declared?(workflow)

        project.browser_proof_go_ahead? || !tester_host?(project)
      end

      def self.tester?(project) = project.tester_mode == Agents::Candidates::ScopeCheck::MODE_ON

      # True when this machine must leave the production release to one that has the browser.
      def self.host_blocked?(workflow, host)
        tester?(workflow.ticket.project) && !host.browser_tester? && !workflow.closer_production_approved_at? &&
          declared?(workflow)
      end

      # True when the machine that took this attempt must try the plan's browser proofs on staging before it
      # tags production: the Tester is on, the machine has the browser, no person did the proof in its place.
      def self.machine_runs?(attempt)
        workflow = attempt.workflow
        attempt.phase == "closer_production" && tester?(workflow.ticket.project) && attempt.host.browser_tester? &&
          !workflow.closer_production_approved_at? && declared?(workflow)
      end

      # What the queue asks of a release for this machine: a person's go-ahead on a plan with a browser proof.
      def self.go_ahead_for?(project, host)
        project.browser_proof_go_ahead? || (tester?(project) && !host.browser_tester?)
      end

      # A machine of the project that could run the proof: it need not be online now.
      def self.tester_host?(project)
        Agents::Host.active.where(organization_id: project.organization_id).where.not(certified_at: nil)
                    .any? { |host| host.browser_tester? && host.repositories.include?(project.key) }
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
