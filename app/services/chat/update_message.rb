# frozen_string_literal: true

module Chat
  # Editing keeps the original position and does not notify recipients again. CYRA-987
  class UpdateMessage < ApplicationService
    def initialize(message:, author:, body:, expected_updated_at:)
      @message = message
      @author = author
      @body = body
      @expected_updated_at = expected_updated_at
    end

    def call
      @message.with_lock do
        return failure(:forbidden, "R403-CHAT-011") unless @author && @message.author_id == @author.id
        return failure(:conflict, "R409-CHAT-011") if @message.deleted? || stale?

        @message.update!(body: @body)
        replace_references
      end
      broadcast
      Result.ok(@message)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(I18n.t("member.chat.messages.invalid"), code: "R422-CHAT-010",
                              status: :unprocessable_content, details: e.record.errors.to_hash))
    end

    private

    def stale? = @message.updated_at.iso8601(6) != @expected_updated_at.to_s

    def replace_references
      conversation = @message.conversation
      resources = Chat::References::Parse.call(text: @message.body.to_s,
                                              organization: conversation.organization,
                                              participants: conversation.audience)
      @message.references.destroy_all
      resources.each do |resource|
        @message.references.create!(referable: resource, organization_id: @message.organization_id)
      end
    end

    def broadcast
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.chat_conversation(@message.conversation),
        target: ActionView::RecordIdentifier.dom_id(@message, :content),
        partial: "member/chat_conversations/message_content", locals: { message: @message }
      )
    end

    def failure(status, code)
      key = status == :forbidden ? "member.forbidden" : "member.chat.messages.stale"
      Result.err(AppError.new(I18n.t(key), code: code, status: status))
    end
  end
end
