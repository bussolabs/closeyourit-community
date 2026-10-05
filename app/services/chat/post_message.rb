# frozen_string_literal: true

module Chat
  # Posta un messaggio in una conversazione già risolta e autorizzata dal controller. In transazione:
  # crea il messaggio, estrae e persiste le risorse taggate (SOLO quelle nell'intersezione delle
  # visibilità dell'audience → "in comune"), aggiorna last_message_at. Il broadcast realtime (Fase 4)
  # e l'enqueue delle notifiche (Fase 5) sono agganciati in #after_post. Clone di Ticketing::AddComment.
  class PostMessage < ApplicationService
    def initialize(conversation:, author:, params:)
      @conversation = conversation
      @author = author
      @params = params
    end

    def call
      message = build_message
      persisted = persist(message)
      return Result.err(invalid(message)) unless persisted

      after_post(message)
      Result.ok(message)
    end

    private

    def build_message
      message = @conversation.messages.new(
        body: @params[:body], author: @author, organization_id: @conversation.organization_id
      )
      message.files.attach(files) if files.present?
      message
    end

    # Atomico: messaggio + riferimenti + last_message_at, o niente. Ritorna true se il messaggio è
    # persistito (i riferimenti invalidi vengono semplicemente scartati, non fanno fallire il messaggio).
    def persist(message)
      ActiveRecord::Base.transaction do
        raise ActiveRecord::Rollback unless message.save

        persist_references(message)
        @conversation.update!(last_message_at: message.created_at)
      end
      message.persisted?
    end

    def persist_references(message)
      resources = Chat::References::Parse.call(
        text: message.body.to_s, organization: @conversation.organization, participants: @conversation.audience
      )
      resources.each do |resource|
        message.references.create(referable: resource, organization_id: @conversation.organization_id)
      end
    end

    # Scarta i placeholder blank del form (hidden "" dell'input file array), come Ticketing::AddComment.
    def files
      Array.wrap(@params[:files]).reject(&:blank?)
    end

    # Realtime + notifiche dopo il commit. Il broadcast appende la bolla al thread (chi ha la show
    # aperta la vede comparire); il job fa il fan-out delle notifiche (enqueue esplicito, non
    # after_commit — coerente con Ticketing).
    def after_post(message)
      broadcast(message)
      Chat::NotifyJob.perform_later(message_id: message.id)
    end

    # Append della bolla sullo stream della conversazione (stesso pattern di Ticketing::AddComment).
    # current_account_id assente → il partial non renderizza il bottone elimina (il broadcast va agli
    # ALTRI; l'autore vede il proprio via redirect/reload con il bottone).
    def broadcast(message)
      Turbo::StreamsChannel.broadcast_append_to(
        Realtime::Streams.chat_conversation(@conversation),
        target: "chat_messages_#{@conversation.id}",
        partial: "member/chat_conversations/message",
        locals: { message: message, conversation: @conversation }
      )
    end

    def invalid(message)
      AppError.new(I18n.t("chat.errors.invalid_message"), code: "R422-CHAT-010",
                   details: message.errors.to_hash)
    end
  end
end
