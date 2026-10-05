# frozen_string_literal: true

module Assistant
  # Starts the assistant's answer to a user message that already has its text: empty reply,
  # bubble, job. Shared by a typed message (PostMessage) and a transcribed one (TranscribeJob). CYRA-908
  class StartReply < ApplicationService
    def initialize(question:)
      @question = question
      @conversation = question.conversation
    end

    def call
      reply = ActiveRecord::Base.transaction do
        @conversation.messages.create!(role: :assistant, status: :streaming, content: nil,
                                       organization_id: @conversation.organization_id)
                     .tap { |message| @conversation.update!(last_message_at: message.created_at) }
      end
      MessageBroadcast.append(reply)
      enqueue(reply)
      Result.ok(reply)
    end

    private

    # Tool loop on: the answer reads data within the scope frozen now (CYRA-906).
    # Tool loop off: the streaming answer from the page catalog only.
    def enqueue(reply)
      delayed = { wait: Assistant::Constants::STREAM_START_DELAY }
      if ::Ai::Feature.disabled?(:assistant_tools)
        return Assistant::StreamReplyJob.set(**delayed).perform_later(message_id: reply.id)
      end

      scope = Authorization::ScopeSnapshot.capture(account: @conversation.account,
                                                   organization: @conversation.organization)
      # A conversation opened from a project reads that project only.
      scope = scope.only_project(@conversation.project_id) if @conversation.project_id
      Assistant::ConverseJob.set(**delayed).perform_later(
        message_id: reply.id, question_id: @question.id,
        project_ids: scope.project_ids, group_ids: scope.group_ids,
        full_access: scope.full_access, scope_listed: true, with_catalog: true
      )
    end
  end
end
