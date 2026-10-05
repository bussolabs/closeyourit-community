# frozen_string_literal: true

module Projects
  module Moves
    # Applies a move in one transaction: everything or nothing. On error the transaction
    # rolls back first, then the move is marked failed outside it (CYRA-879).
    class Execute < ApplicationService
      Blocked = Class.new(StandardError)

      def initialize(move:)
        @move = move
        @subject = Subject.new(move.subject)
        @destination = move.destination_organization
      end

      def call
        return Result.err(AppError.new("Move is not pending", code: "R409-PROJECTMOVE-006", status: :conflict)) unless claim!

        ApplicationRecord.transaction(requires_new: true) do
          lock!
          ensure_unblocked!
          apply!
          record_history
        end
        @shared&.keep_uploads!
        @move.update!(status: :succeeded, finished_at: Time.current)
        Result.ok(@move)
      rescue Blocked => error
        fail_with(AppError.new(error.message, code: "R409-PROJECTMOVE-001", status: :conflict))
      rescue AppError => error
        fail_with(error)
      rescue StandardError => error
        fail_with(AppError.new(error.message, code: "R422-PROJECTMOVE-002"))
      end

      private

      # Only a pending move runs: a retried job or a double submit leaves a finished move alone (CYRA-879).
      def claim!
        @move.with_lock { @move.pending? && @move.update!(status: :running) }
      end

      # Same order as Projects::Destroy: limit policies, then projects. The group row goes first, so its
      # project list is read once no project can join it any more (CYRA-879). Knowledge pages and books
      # go last: their lists are fixed here and used by every later step (CYRA-882).
      def lock!
        Projects::Group.where(id: @subject.group_ids).lock.load
        Agents::LimitPolicy.where(project_id: @subject.project_ids).order(:id).lock.load
        Projects::Project.where(id: @subject.project_ids).order(:id).lock.load
        @subject.lock_knowledge!
      end

      # The plan runs again under the locks; the move itself is active and must not block (CYRA-879).
      def ensure_unblocked!
        report = Plan.call(subject: @subject, destination: @destination, move: @move).value
        return unless report.blocked?

        raise Blocked, report.blockers.map { "#{_1[:code]}: #{_1[:detail]}" }.join("; ")
      end

      # follow! goes last: Detach.scope finds rows by project, ticket or group, never by organization (CYRA-879).
      def apply!
        lookups = LookupMap.new(subject: @subject, destination: @destination).apply!
        @shared = SharedSecrets.new(subject: @subject, destination: @destination)
        @shared.apply!(environments: lookups.fetch("types_environments", {}), actor: @move.requested_by)
        remap_lookups(lookups)
        knowledge = KnowledgeBase.new(subject: @subject, destination: @destination)
        knowledge.relink!
        Detach.apply!(@subject)
        leave_source_group
        drop_foreign_watchers
        drop_foreign_participants
        Github.apply!(@subject)
        follow!
        knowledge.apply!(actor: @move.requested_by)
      end

      def remap_lookups(lookups)
        Registry::LOOKUPS.each do |table, columns|
          relation = Detach.scope(table, @subject)
          columns.each do |column, lookup|
            lookups.fetch(lookup, {}).each { |from, to| relation.where(column => from).update_all(column => to) }
          end
        end
      end

      # A project moved alone leaves its group in the source organization (CYRA-879).
      def leave_source_group
        return if @subject.group?

        Projects::Project.where(id: @subject.project_ids).update_all(group_id: nil)
      end

      def drop_foreign_watchers
        members = Connections::Membership.where(organization_id: @destination.id).select(:account_id)
        Ticketing::Subscription.where(ticket_id: @subject.ticket_ids).where.not(account_id: members).delete_all
      end

      # A participant must be a member of the conversation's organization (CYRA-879).
      def drop_foreign_participants
        members = Connections::Membership.where(organization_id: @destination.id).select(:account_id)
        Chat::Participant.where(conversation_id: conversations.select(:id)).where.not(account_id: members).delete_all
      end

      # Polymorphic rows follow only from the source: an earlier move's moved_out row stays put (CYRA-879).
      def follow!
        Registry::FOLLOW.each { |table, sql| move_rows(Detach.rows(table, sql, @subject)) }
        Registry::POLYMORPHIC_FOLLOW.each do |table, prefix|
          move_rows(polymorphic_rows(table, prefix).where(organization_id: @move.source_organization_id))
        end
        follow_chat!
        move_rows(Secrets::Provision.where(source_project_id: @subject.project_ids))
      end

      # Detach already removed the references to what the source keeps (CYRA-879).
      def follow_chat!
        messages = Chat::Message.where(conversation_id: conversations.select(:id))
        move_rows(Chat::MessageReference.where(message_id: messages.select(:id)))
        move_rows(messages)
        move_rows(Chat::Participant.where(conversation_id: conversations.select(:id)))
      end

      def conversations = polymorphic_rows("chat_conversations", "contextable")

      def polymorphic_rows(table, prefix) = Detach.rows(table, Detach.polymorphic_sql(prefix), @subject)

      def move_rows(relation) = relation.update_all(organization_id: @destination.id)

      # moved_out is written after follow! so the source organization keeps it (CYRA-879).
      def record_history
        record = @move.subject.reload
        actor = @move.requested_by
        Activity::Record.call(subject: record, action: "moved_in", actor:, data: { from: @move.source_organization.name })
        Activity::Event.create!(organization_id: @move.source_organization_id, subject: record, action: "moved_out",
                                actor:, actor_name: actor&.name, data: { "to" => @destination.name })
      end

      # The rollback leaves the stored copies of shared files behind: they are deleted here (CYRA-879).
      def fail_with(error)
        @shared&.discard_uploads!
        @move.update!(status: :failed, error_message: error.message.truncate(1_000), finished_at: Time.current)
        Result.err(error)
      end
    end
  end
end
