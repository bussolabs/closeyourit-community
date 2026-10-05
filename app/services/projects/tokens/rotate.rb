# frozen_string_literal: true

module Projects
  module Tokens
    # Ruota una credenziale: emette un nuovo token e revoca quello vecchio, in una transazione.
    # Restituisce { new: <Issue result hash>, revoked: <old token> } — il nuovo segreto è in new[:secret].
    #
    # Scadenza (CYRA-716): il nuovo token eredita la DURATA del vecchio, non la sua data. Ereditare la
    # data farebbe nascere il sostituto già scaduto (o in scadenza il giorno dopo) proprio nel momento
    # in cui lo si sostituisce perché sta per scadere; non ereditare niente trasformerebbe in silenzio
    # una credenziale a termine in una perpetua, che è il difetto che questo ticket chiude.
    class Rotate < ApplicationService
      def initialize(token:, host:, name: nil, created_by: nil)
        @token = token
        @host = host
        @name = name
        @created_by = created_by
      end

      def call
        issued = nil
        ActiveRecord::Base.transaction do
          issue = Issue.call(
            project: @token.project,
            name: @name || @token.name,
            host: @host,
            environment: @token.environment,
            created_by: @created_by || @token.created_by,
            scopes: @token.scopes,
            expires_at: inherited_expires_at
          )
          raise ActiveRecord::Rollback if issue.err?

          issued = issue.value
          Revoke.call(token: @token)
        end

        return Result.err(AppError.new("Rotazione fallita", code: "R422-TOKEN-003")) if issued.nil?

        Result.ok({ new: issued, revoked: @token.reload })
      end

      private

      # Durata del vecchio token (emissione → scadenza) riportata a partire da adesso. nil se il
      # vecchio non aveva scadenza: perpetuo resta perpetuo.
      def inherited_expires_at
        return nil if @token.expires_at.blank?

        Time.current + (@token.expires_at - @token.created_at)
      end
    end
  end
end
