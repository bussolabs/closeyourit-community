# frozen_string_literal: true

# Canale del thread di una conversazione di chat: gestisce le azioni client→server (typing, mark_read)
# e fa da gate d'accesso. Il flusso server→client HTML (append messaggi, update typing/receipt) passa
# dal Turbo::StreamsChannel sottoscritto in view con turbo_stream_from — qui broadcastiamo su QUELLO
# stesso stream (org-prefissato da Realtime::Streams).
#
# Sicurezza/tenant: identità dalla Connection (current_account/current_organization già anti-BOLA).
# subscribed autorizza via Chat::Conversation#accessible_by? (DM → partecipante; canale → contesto
# visibile) e crea lazy la riga partecipante (stato). Accesso negato → reject.
class ChatConversationChannel < ApplicationCable::Channel
  def subscribed
    conversation = resolve_conversation
    return reject unless conversation

    @conversation = conversation
    Chat::Participant.ensure_for(conversation: @conversation, account: current_account)
  end

  # Il client segnala che sta scrivendo (throttlato lato JS). Broadcast dell'indicatore transiente:
  # il controller Stimulus nasconde l'eco per l'autore e lo pulisce dopo il timeout.
  def typing(_data = {})
    return unless @conversation && resolve_conversation

    broadcast_in_locale(target: "chat_typing_#{@conversation.id}", partial: "member/chat_conversations/typing",
                        locals: { account: current_account, conversation: @conversation })
  end

  # Il client segnala che ha letto (focus/scroll-bottom): aggiorna last_read_at e ribroadcasta le
  # ricevute così gli altri vedono "letto da …".
  def mark_read(_data = {})
    return unless @conversation && resolve_conversation

    Chat::Participant.ensure_for(conversation: @conversation, account: current_account).mark_read!
    broadcast_in_locale(target: "chat_receipts_#{@conversation.id}", partial: "member/chat_conversations/receipts",
                        locals: { conversation: @conversation })
  end

  private

  # Il canale non passa dal controller che sceglie la lingua: senza questo il testo usciva in inglese.
  def broadcast_in_locale(**options)
    I18n.with_locale(current_account.effective_locale) do
      Turbo::StreamsChannel.broadcast_update_to(Realtime::Streams.chat_conversation(@conversation), **options)
    end
  end

  def resolve_conversation
    return if current_organization.blank? || current_account.blank?

    account = connection.live_account
    return unless account

    conversation = Chat::Conversation.find_by(id: params[:id], organization_id: current_organization.id)
    return unless conversation&.accessible_by?(account)

    conversation
  rescue StandardError
    nil
  end
end
