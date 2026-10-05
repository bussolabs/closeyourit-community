# frozen_string_literal: true

module Cli
  module V1
    # Credenziali di ingest per-progetto (Projects::Token) gestite da terminale. Gate tokens.manage.
    # create/rotate rivelano il segreto + DSN UNA sola volta (come la UI member, reveal-once).
    class TokensController < Cli::V1::BaseController
      before_action :set_project!
      before_action :require_tokens_manage

      def index
        tokens = @project.tokens.includes(:environment).order(revoked_at: :asc, created_at: :desc)
        render_ok(ProjectTokenSerializer.new(tokens))
      end

      def create
        environment = @project.environments.find_by(id: params[:environment_id])
        result = ::Projects::Tokens::Issue.call(
          project: @project, name: params[:name], host: request.host,
          environment: environment, created_by: Current.account, expires_at: expires_at_param
        )
        if result.ok?
          render_revealed(result.value, status: :created)
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        token = @project.tokens.find(params[:id])
        ::Projects::Tokens::Revoke.call(token:)
        render_no_content
      end

      private

      def require_tokens_manage
        require_permission!("tokens.manage", scope: @project)
      end

      # Scadenza facoltativa (CYRA-716). Una data illeggibile diventa nil e NON un errore di parsing
      # a 500: il modello poi rifiuta le date nel passato con R422-TOKEN-001, che è la risposta che
      # il terminale sa già leggere.
      def expires_at_param
        raw = params[:expires_at].presence
        return nil if raw.nil?

        Time.zone.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      # Reveal-once: il segreto bearer + DSN viaggiano solo qui, nella risposta alla creazione/rotazione.
      def render_revealed(value, status:)
        render json: {
          data: {
            token: ProjectTokenSerializer.new(value[:token]).as_json,
            secret: value[:secret],
            dsn: value[:dsn],
            sentry_dsn: value[:sentry_dsn]
          }
        }, status: status
      end
    end
  end
end
