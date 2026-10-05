# frozen_string_literal: true

module Member
  # Credenziali di ingest per-progetto (Fase 1). Lista (active+revoked), creazione con
  # reveal-once del segreto bearer + DSN, revoca. Gestione admin/owner; scoping anti-BOLA all'org.
  # Controller flat (non Member::Projects::*) per non ombreggiare il namespace ::Projects (model).
  class ProjectTokensController < Member::BaseController
    include Member::ProjectSettingsPage

    # CYRA-883 — the list lives in the Settings page. The old address, still linked from guides,
    # expiry e-mails and next steps, forwards there with its search, filter, sort and page.
    FORWARDED_PARAMS = %w[q status sort page per].freeze

    before_action :set_project
    before_action :require_tokens

    def index
      redirect_to member_project_settings_path(@project, **forwarded_params, anchor: "tokens")
    end

    def create
      environment = @project.environments.find_by(id: params[:environment_id])
      result = ::Projects::Tokens::Issue.call(
        project: @project,
        name: params[:name],
        host: request.host,
        environment: environment,
        created_by: Current.account,
        expires_at: expires_at_param
      )

      if result.ok?
        # Reveal-once: il segreto e il DSN sono mostrati UNA sola volta, qui, senza finire in DB.
        # Render diretto (no redirect) per non scrivere il segreto nel cookie di sessione.
        @revealed = result.value
        load_settings
        render "member/project_settings/show", status: :created
      else
        @token_errors = result.error.details || { base: [ result.error.message ] }
        load_settings
        render "member/project_settings/show", status: :unprocessable_content
      end
    end

    def destroy
      token = @project.tokens.find(params[:id])
      ::Projects::Tokens::Revoke.call(token: token)
      redirect_to member_project_settings_path(@project, anchor: "tokens"), notice: t("member.tokens.revoked")
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def forwarded_params
      request.query_parameters.slice(*FORWARDED_PARAMS).symbolize_keys
    end

    # Scadenza facoltativa (CYRA-716): il campo del form è un <input type="date">, quindi arriva una
    # data senza ora. La si porta a fine giornata perché "scade il 30" per chi la scrive vuol dire che
    # il 30 il token funziona ancora. Una data illeggibile diventa nil e la validazione del modello fa
    # il resto: nessun 500 da parsing.
    def expires_at_param
      raw = params[:expires_at].presence
      return nil if raw.nil?

      Date.parse(raw.to_s).end_of_day
    rescue Date::Error
      nil
    end

    def require_tokens
      require_permission!("tokens.manage", scope: @project)
    end
  end
end
