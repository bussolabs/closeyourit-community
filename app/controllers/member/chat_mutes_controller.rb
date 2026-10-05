# frozen_string_literal: true

module Member
  # Silenzia/riattiva le notifiche di una conversazione per l'account corrente (muted_at). Singleton
  # PUT (mute) / DELETE (unmute). La riga partecipante si crea lazy (canali) via ensure_for.
  class ChatMutesController < Member::BaseController
    permission_not_required "Silenzia una conversazione visibile per sé: tocca la propria riga di partecipazione, " \
                            "quella di nessun altro."

    before_action :set_participant

    def update
      @participant.update!(muted_at: Time.current)
      redirect_to member_chat_conversation_path(@participant.conversation), notice: t("member.chat.muted")
    end

    def destroy
      @participant.update!(muted_at: nil)
      redirect_to member_chat_conversation_path(@participant.conversation), notice: t("member.chat.unmuted")
    end

    private

    def set_participant
      conversation = Chat::Conversation.visible_to(account: Current.account, organization: Current.organization)
                                       .find(params[:conversation_id])
      @participant = Chat::Participant.ensure_for(conversation: conversation, account: Current.account)
    end
  end
end
