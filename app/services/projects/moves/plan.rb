# frozen_string_literal: true

module Projects
  module Moves
    # The dry run of a move: what blocks it, what it creates in the destination and
    # which links it detaches. Read-only; Execute runs it again inside its transaction (CYRA-879).
    class Plan < ApplicationService
      Report = Data.define(:blockers, :creations, :detachments) do
        def blocked? = blockers.any?
      end

      # `move` is the record Execute runs: it is active by then and must not block itself (CYRA-879).
      def initialize(subject:, destination:, move: nil)
        @subject = subject
        @destination = destination
        @move = move
      end

      def call
        shared = SharedSecrets.new(subject: @subject, destination: @destination)
        knowledge = KnowledgeBase.new(subject: @subject, destination: @destination)
        Result.ok(Report.new(blockers: blockers(shared, knowledge), creations: creations(shared, knowledge),
                             detachments: detachments(knowledge)))
      end

      private

      def blockers(shared, knowledge)
        [ *premises_changed, *key_taken, *people_not_members, *provisions_crossing, *agents_running, *team_puckies, *move_in_progress,
          *shared.conflicts.map { { code: "shared_conflict", detail: "#{_1[:kind]} #{_1[:name]} (#{_1[:environment_code]})" } },
          *knowledge.conflicts.map { { code: "knowledge_publication_conflict", detail: _1 } },
          *knowledge.orphaned_titles.map { { code: "knowledge_book_orphaned", detail: _1 } } ]
      end

      def creations(shared, knowledge)
        LookupMap.new(subject: @subject, destination: @destination).missing +
          shared.copies.map { _1.merge(table: "secrets_shared") } + knowledge.creations
      end

      # What the page checked before queueing the move, checked again by Execute under its locks (CYRA-879).
      def premises_changed
        return [] unless @move

        [ *subject_left_source, *requester_not_owner ]
      end

      def subject_left_source
        record = @subject.record
        return [] if record.class.where(id: record.id).pick(:organization_id) == @move.source_organization_id

        [ { code: "subject_left_source", detail: @subject.label } ]
      end

      def requester_not_owner
        organizations = [ @move.source_organization_id, @move.destination_organization_id ]
        owned = Connections::Membership.where(account_id: @move.requested_by_id, role: :owner, organization_id: organizations)
        return [] if @move.requested_by_id && owned.distinct.count(:organization_id) == organizations.size

        [ { code: "requester_not_owner", detail: @move.requested_by&.name.to_s } ]
      end

      def key_taken
        keys = projects.pluck(:key)
        Projects::Project.where(organization_id: @destination.id, key: keys).order(:key).pluck(:key)
                         .map { { code: "key_taken", detail: _1 } }
      end

      def people_not_members
        members = Connections::Membership.where(organization_id: @destination.id).select(:account_id)
        Accounts::Account.where(id: active_people_ids).where.not(id: members).order(:email)
                         .map { { code: "person_not_member", detail: "#{_1.name} <#{_1.email}>" } }
      end

      # Watchers are not here: Execute drops the ones who are not members (CYRA-879).
      def active_people_ids
        ids = @subject.project_ids
        open_tickets = Ticketing::Ticket.where(project_id: ids).where.not(status_id: Types::TicketStatus.category_done.select(:id))
        [ projects.pluck(:cto_id, :default_assignee_id),
          open_tickets.pluck(:assignee_id, :reviewer_id),
          Errors::Group.where(project_id: ids).pluck(:assignee_id),
          Connections::ProjectMembership.where(project_id: ids).pluck(:account_id),
          Connections::GroupMembership.where(group_id: @subject.group_ids).pluck(:account_id),
          Connections::AccountSecretAccess.where(project_id: ids).pluck(:account_id),
          Secrets::Override.where(project_id: ids).pluck(:account_id) ].flatten.compact.uniq
      end

      def provisions_crossing
        ids = @subject.project_ids
        Secrets::Provision.where(source_project_id: ids).where.not(destination_project_id: ids)
                          .or(Secrets::Provision.where(destination_project_id: ids).where.not(source_project_id: ids))
                          .includes(:source_project, :destination_project)
                          .map { { code: "provision_crosses", detail: "#{_1.source_project.key} → #{_1.destination_project.key}" } }
      end

      # A workflow blocks while open, not blocked and touched within STALE_AFTER, or while automation
      # still watches it: an open release probe or a delivery candidate awaiting its next check (CYRA-882).
      def agents_running
        tickets = Ticketing::Ticket.where(project_id: @subject.project_ids)
        leased = Agents::Lease.where(ticket_id: tickets.select(:id)).where(expires_at: Time.current..).select(:ticket_id)
        tickets.where(id: leased).or(tickets.where(id: running_workflows(tickets).select(:ticket_id)))
               .includes(:project).order(:number).map { { code: "agent_running", detail: _1.code } }
      end

      # Only open workflows count: a failed probe stops its workflow but never closes, so it must be
      # within GRACE_WINDOW too (CYRA-882).
      def running_workflows(tickets)
        workflows = Agents::Workflow.where(ticket_id: tickets.select(:id), cancelled_at: nil, completed_at: nil, blocked_at: nil)
        watched = Agents::WorkflowProbe.live.where(bound_at: Agents::WorkflowProbe::GRACE_WINDOW.ago..).select(:workflow_id)
        checking = Agents::DeliveryCandidate.retryable.where.not(next_check_at: nil).select(:workflow_id)
        workflows.where(updated_at: Projects::Move::STALE_AFTER.ago..)
                 .or(workflows.where(id: watched)).or(workflows.where(id: checking))
      end

      # A team Puck belongs to the source organization and to one project: it blocks the move (CYRA-1023).
      def team_puckies
        Coworkers::Puck.where(project_id: @subject.project_ids).order(:name)
                       .map { { code: "team_puck_bound", detail: _1.name } }
      end

      # One active move per project or group: a group overlaps with its projects and vice versa (CYRA-879).
      def move_in_progress
        group_ids = @subject.group_ids | projects.where.not(group_id: nil).distinct.pluck(:group_id)
        active = Projects::Move.active.where.not(id: @move&.id)
        overlapping = active.where(subject_type: Projects::Project.name, subject_id: @subject.project_ids)
                            .or(active.where(subject_type: Projects::Group.name, subject_id: group_ids))
        return [] unless overlapping.exists?

        [ { code: "move_in_progress", detail: @subject.label } ]
      end

      def detachments(knowledge)
        counts = Registry::DETACH.keys.filter_map do |table|
          count = Detach.affected(table, @subject).count
          { table:, count: } if count.positive?
        end
        counts + group_link + Github.preview(@subject) + relinked_books(knowledge)
      end

      def relinked_books(knowledge)
        count = knowledge.relinked_count
        count.positive? ? [ { table: "knowledge_books", count: } ] : []
      end

      # A project moved alone leaves its group in the source: Execute clears group_id (CYRA-879).
      def group_link
        return [] if @subject.group? || projects.where.not(group_id: nil).none?

        [ { table: "projects_groups", count: 1 } ]
      end

      def projects = Projects::Project.where(id: @subject.project_ids)
    end
  end
end
