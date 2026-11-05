# frozen_string_literal: true

module Ticketing
  module StalledEpics
    # Open epics whose open children all wait for someone and none moves (CYRA-1155). Each wait says
    # who has to act and on what. Every read is in bulk for all the children, never one per child.
    #
    #   Ticketing::StalledEpics::Detect.call(organization: nil) → Result.ok([Stall, …])
    class Detect < ApplicationService
      DONE_CATEGORY = ::Types::TicketStatus.categories.fetch("done")

      # kind: a human-gated workflow phase, "question" or "dependency". ref_id names the thing
      # waited on, detail is what the reader sees (question text or prerequisite code).
      Wait = Data.define(:child, :kind, :account, :ref_id, :detail)

      Stall = Data.define(:epic, :waits) do
        # Same waits, same fingerprint: the notice is sent again only when the situation changes.
        def fingerprint
          tuples = waits.map { |wait| [ wait.child.id, wait.kind, wait.ref_id, wait.account&.id ].join(":") }
          Digest::SHA256.hexdigest(tuples.sort.join("|"))[0, 16]
        end
      end

      def initialize(organization: nil)
        @organization = organization
      end

      def call
        children = open_children
        return Result.ok([]) if children.empty?

        states = ::Agents::Workflows::InFlight.states_by_workflow(children.filter_map { |child| live_workflow(child) })
        questions = blocking_questions(children)
        dependencies = unmet_dependencies(children)

        stalls = children.group_by(&:parent_id).filter_map do |epic_id, siblings|
          waits_by_child = siblings.to_h do |child|
            [ child, waits_for(child, states[live_workflow(child)&.id], questions[child.id], dependencies[child.id]) ]
          end
          next unless waits_by_child.values.all?(&:any?)

          [ epic_id, waits_by_child.values.flatten ]
        end
        epics = Ticketing::Ticket.where(id: stalls.map(&:first)).preload(:assignee, :project).index_by(&:id)
        Result.ok(stalls.map { |epic_id, waits| Stall.new(epic: epics.fetch(epic_id), waits:) })
      end

      private

      def open_children
        epics = Ticketing::Ticket.kind_epic.joins(:status).where.not(types_ticket_statuses: { category: DONE_CATEGORY })
        epics = epics.where(project_id: Projects::Project.where(organization_id: @organization.id).select(:id)) if @organization
        Ticketing::Ticket.where(parent_id: epics.select(:id))
                         .joins(:status).where.not(types_ticket_statuses: { category: DONE_CATEGORY })
                         .preload(:status, :reporter, :agent_workflow, project: [ :cto, { organization: :cto } ])
                         .order(:number).to_a
      end

      def live_workflow(child)
        workflow = child.agent_workflow
        workflow if workflow && !workflow.cancelled_at? && !workflow.completed_at?
      end

      # No waits means the child moves: the automation works on it (queued included), a person
      # moved it into progress by hand, or nobody holds it. Any of them keeps the epic going.
      def waits_for(child, state, questions, dependencies)
        return [] if state&.dig(:state) == "running"

        waits = []
        if state&.dig(:state) == "waiting" && ::Agents::Workflows::PhaseResolver.waiting_on_you?(state[:phase])
          waits << Wait.new(child:, kind: state[:phase], account: technical_lead(child), ref_id: child.agent_workflow.id, detail: nil)
        end
        Array(questions).each do |question|
          account = question.origin_agent? ? technical_lead(child) : child.reporter
          waits << Wait.new(child:, kind: "question", account:, ref_id: question.id, detail: question.body)
        end
        Array(dependencies).each do |dependency|
          blocker = dependency.blocker
          waits << Wait.new(child:, kind: "dependency", account: blocker.assignee, ref_id: blocker.id, detail: blocker.code)
        end
        waits
      end

      def technical_lead(child) = child.project.effective_cto

      def blocking_questions(children)
        Ticketing::Question.blocking_open.where(ticket_id: children.map(&:id)).chronological.group_by(&:ticket_id)
      end

      def unmet_dependencies(children)
        Connections::TicketDependency.unmet.where(ticket_id: children.map(&:id))
                                     .preload(blocker: [ :assignee, :project ]).group_by(&:ticket_id)
      end
    end
  end
end
