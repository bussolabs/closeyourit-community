# frozen_string_literal: true

module Assistant
  # Records the user's turn and starts the reply through Assistant::StartReply: the question's bubble
  # appears at once, the reply is born empty and a job fills it. The controller already resolved the
  # conversation within the account's ownership. CYRA-908
  class PostMessage < ApplicationService
    def initialize(conversation:, text:, correction_of: nil)
      @conversation = conversation
      # Cap difensivo: un input abnorme non deve gonfiare DB e prompt del server AI.
      @text = text.to_s.strip.truncate(Assistant::Constants::MAX_MESSAGE_CHARS)
      @correction_of = correction_of
    end

    def call
      return Result.err(blank_error) if @text.blank?
      # Il gate sta QUI e non in StreamReplyJob: con l'assistente spento dal god l'utente lo scopre
      # subito, invece di vedere la propria domanda accolta e una bolla che non si riempirà mai. E
      # nessun messaggio nasce per finire fallito: la conversazione non si sporca di tentativi vuoti.
      # Il secondo gate — «questa organizzazione ha collegato il servizio» (CYRA-547) — è sparito con
      # le chiavi per organizzazione: l'AI la offre il sistema (CYRA-765). Se la configurazione manca
      # è un guasto di esercizio, e lo dice il job chiudendo la bolla con R502-LLM-002.
      return Result.err(::Ai::Feature.disabled_error(:assistant_chat)) if ::Ai::Feature.disabled?(:assistant_chat)

      user_message = persist
      MessageBroadcast.append(user_message)
      discard_stale_proposals
      # The reply starts with a short delay so a freshly rendered panel can subscribe first; the
      # `ui--assistant-reconcile` fallback covers a lost broadcast (STREAM_START_DELAY).
      StartReply.call(question: user_message)
    end

    private

    def persist
      ActiveRecord::Base.transaction do
        @conversation.messages.create!(role: :user, status: :complete, content: @text,
                                       organization_id: @conversation.organization_id)
                     .tap { @conversation.update!(title: derived_title) }
      end
    end

    # "Correct and resend": the cards still waiting under the replies to the corrected message
    # answered a misheard sentence, so they are discarded and their bubbles redrawn. CYRA-908
    def discard_stale_proposals
      original = @correction_of.presence && @conversation.messages.role_user.find_by(id: @correction_of)
      return if original.nil?

      stale = @conversation.messages.role_assistant.where(created_at: original.created_at..)
                           .joins(:proposals).merge(Assistant::Proposal.status_pending).distinct
      stale.each do |reply|
        reply.proposals.status_pending.update_all(status: Assistant::Proposal.statuses[:discarded],
                                                  updated_at: Time.current)
        MessageBroadcast.replace(reply.reload)
      end
    end

    # Titolo leggibile della conversazione per la lista "riprendi": la prima domanda, troncata. Non
    # sovrascrive un titolo già impostato.
    def derived_title
      @conversation.title.presence || @text.truncate(60)
    end

    def blank_error
      AppError.new(I18n.t("member.assistant.errors.blank"), code: "R422-ASSISTANT-001",
                   status: :unprocessable_content)
    end
  end
end
