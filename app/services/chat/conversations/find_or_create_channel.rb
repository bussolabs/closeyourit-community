# frozen_string_literal: true

module Chat
  module Conversations
    # Trova o crea il canale di un contesto (Projects::Project o Teams::Team). Idempotente per contesto.
    # L'accesso ai canali è relazionale: l'actor deve poter vedere il contesto (VisibleScope per i
    # progetti, appartenenza per i team). Crea solo la riga di stato dell'actor (non partecipanti per
    # tutti — l'audience è calcolata a runtime). Result pattern.
    class FindOrCreateChannel < ApplicationService
      def initialize(organization:, contextable:, actor:)
        @organization = organization
        @contextable = contextable
        @actor = actor
      end

      def call
        return Result.err(error("invalid_context", "R422-CHAT-005")) unless valid_context?
        return Result.err(error("not_accessible", "R403-CHAT-006", :forbidden)) unless accessible?

        conversation = find_or_create
        return Result.err(invalid(conversation)) unless conversation&.persisted?

        Chat::Participant.ensure_for(conversation: conversation, account: @actor)
        Result.ok(conversation)
      end

      private

      def kind
        @contextable.is_a?(Projects::Project) ? :project : :team
      end

      def valid_context?
        @contextable.is_a?(Projects::Project) || @contextable.is_a?(Teams::Team)
      end

      def find_or_create
        Chat::Conversation.find_or_create_by(organization: @organization, contextable: @contextable) do |conversation|
          conversation.kind = kind
          conversation.created_by = @actor
        end
      rescue ActiveRecord::RecordNotUnique
        Chat::Conversation.find_by(organization: @organization, contextable: @contextable)
      end

      def accessible?
        case @contextable
        when Projects::Project
          Authorization::VisibleScope.new(account: @actor, organization: @organization)
                                     .projects.exists?(id: @contextable.id)
        when Teams::Team
          @actor.teams.where(organization_id: @organization.id).exists?(id: @contextable.id)
        else
          false
        end
      end

      def error(key, code, status = :unprocessable_content)
        AppError.new(I18n.t("chat.errors.#{key}"), code: code, status: status)
      end

      def invalid(conversation)
        AppError.new(I18n.t("chat.errors.invalid_conversation"), code: "R422-CHAT-007",
                     details: conversation&.errors&.to_hash)
      end
    end
  end
end
