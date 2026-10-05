# frozen_string_literal: true

module Member
  # Spoken message to the assistant. The panel's microphone names the conversation on screen; the
  # topbar one goes to the most recent conversation (or a new one), the one the panel reopens on. CYRA-908
  class AssistantVoiceController < Member::BaseController
    permission_not_required "Messages in the account's own assistant conversation: ownership is the scope."

    def create
      scope = Assistant::Conversation.for(account: Current.account, organization: Current.organization)
      conversation = if params[:conversation_id].present?
        scope.find(params[:conversation_id])
      else
        scope.ordered.first || scope.create!
      end

      result = Assistant::PostVoiceMessage.call(conversation: conversation, audio: params[:audio])
      return head(:no_content) if result.ok?

      render plain: result.error.message, status: result.error.status
    end
  end
end
