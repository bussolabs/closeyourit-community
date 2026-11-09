# frozen_string_literal: true

module Agents
  module Workflows
    # Approving an epic's split creates its children and the prerequisites among them, in the
    # approver's name: a prerequisite is a person's decision (Connections::TicketDependency). Runs
    # inside ApprovePlan's transaction and raises on any error, so all of it is created or none. The
    # epic's run ends here: the code is written by its children, not by the epic (CYRA-1152).
    class SplitEpic
      Failed = Class.new(StandardError) do
        attr_reader :error

        def initialize(error)
          @error = error
          super(error.message)
        end
      end

      def self.call(...) = new(...).call

      def initialize(workflow:, plan:, actor:, now:)
        @workflow = workflow
        @plan = plan
        @actor = actor
        @now = now
      end

      # → the children created, in the order they can start.
      def call
        split = @plan.split
        problem = split.problem(epic)
        fail!(problem) if problem

        children = split.ordered.to_h { |child| [ child.id, create_child!(child) ] }
        split.ordered.each do |child|
          child.dependencies.each { |id| add_prerequisite!(children.fetch(child.id), children.fetch(id)) }
        end
        @workflow.update!(completed_at: @now)
        children.values
      end

      private

      def epic = @workflow.ticket

      def create_child!(child)
        result = Ticketing::CreateTicket.call(organization: @workflow.organization, reporter: @actor,
                                              true_actor: @actor, params: child_params(child))
        raise Failed, result.error if result.err?

        result.value
      end

      def child_params(child)
        { project_id: epic.project_id, parent_id: epic.id, kind: :story, title: child.title,
          description: child.description,
          status_id: Ticketing::FormOptions.default_status_id(@workflow.organization),
          priority_id: epic.priority_id, scenarios_attributes: scenario_attributes(child) }
      end

      def scenario_attributes(child)
        child.scenarios.each_with_index.map do |scenario, position|
          { title: scenario["title"], step_given: scenario["given"], step_when: scenario["when"],
            step_then: scenario["then"], step_expected: scenario["expected"], position: }
        end
      end

      def add_prerequisite!(ticket, blocker)
        fail!(:prerequisite) unless Connections::TicketDependency.new(ticket:, blocker:, created_by: @actor).save
        Ticketing::RecordActivity.call(ticket:, actor: @actor, action: "dependency_added",
                                       data: { code: blocker.code, title: blocker.title })
      end

      def fail!(problem)
        raise Failed, AppError.new("La divisione proposta non vale per questo ticket (#{problem})",
                                   code: "R409-WORKFLOW-018", status: :conflict)
      end
    end
  end
end
