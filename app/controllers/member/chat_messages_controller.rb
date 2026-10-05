# frozen_string_literal: true

module Member
  # Messaggi di una conversazione. Scrittura via Chat::PostMessage (parsa i tag, persiste i riferimenti
  # in comune). Eliminazione: l'autore sempre; altrui solo con chat.moderate sul progetto del canale.
  class ChatMessagesController < Member::BaseController
    permission_not_required "Scrivere in una conversazione che si vede è baseline: il confine è la visibilità " \
                            "della conversazione.",
                            only: %i[create]

    before_action :set_conversation
    before_action :set_owned_message, only: %i[edit update]

    def edit
      @expected_updated_at = @message.updated_at.iso8601(6)
    end

    def update
      @expected_updated_at = params[:expected_updated_at]
      result = Chat::UpdateMessage.call(message: @message, author: Current.account,
                                        body: params[:body], expected_updated_at: @expected_updated_at)
      if result.ok?
        redirect_to member_chat_conversation_path(@conversation), notice: t("member.chat.messages.updated")
      else
        @message.body = params[:body]
        @error = result.error.message
        render :edit, status: result.error.status
      end
    end

    def create
      result = Chat::PostMessage.call(conversation: @conversation, author: Current.account, params: message_params)
      redirect_to member_chat_conversation_path(@conversation),
                  alert: (result.err? ? result.error.message : nil)
    end

    def destroy
      message = @conversation.messages.kept.find(params[:id])
      return redirect_to(member_chat_conversation_path(@conversation), alert: t("member.forbidden")) unless can_delete?(message)
      return unless confirm_moderation!(message)

      Chat::DeleteMessage.call(message: message)
      redirect_to member_chat_conversation_path(@conversation), notice: t("member.chat.messages.deleted")
    end

    private

    def set_owned_message
      note_permission_check!
      @message = @conversation.messages.kept.where(author: Current.account).find(params[:id])
    end

    # Anti-BOLA: conversazione non visibile → 404.
    def set_conversation
      @conversation = Chat::Conversation.visible_to(account: Current.account, organization: Current.organization)
                                        .find(params[:conversation_id])
    end

    def message_params
      params.permit(:body, files: [])
    end

    # CYRA-728 — moderare è cancellare quello che ha scritto un altro, e passa da una chiave che il
    # catalogo segna pericolosa: qui la conferma serve. Il proprio commento si cancella senza
    # cerimonie — è roba di chi lo cancella, e chiedergli il permesso su sé stesso non protegge
    # nessuno.
    def confirm_moderation!(message)
        return true if message.author_id == Current.account.id

        enforce_dangerous_confirmation!("chat.moderate", scope: @conversation.contextable)
    end

    def can_delete?(message)
      note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
      message.author_id == Current.account.id || can_moderate?
    end

    # Moderazione solo sui canali di progetto (chat.moderate scoped al progetto). DM/team: solo l'autore.
    def can_moderate?
      @conversation.kind_project? && can?("chat.moderate", scope: @conversation.contextable)
    end
  end
end
