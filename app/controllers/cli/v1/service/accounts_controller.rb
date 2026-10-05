# frozen_string_literal: true

module Cli
  module V1
    module Service
      # Gestione dei service account (membri di tipo AI, CLI-only) da terminale. Parità col canale Member
      # web: gate members.manage, stessa logica via i service condivisi (Accounts::Service::{Create,Retire}).
      # Anti-BOLA: scope org via Current.organization.accounts.service → id di un'altra org / account umano
      # → R404. Model SEMPRE ::Accounts::* fully-qualified (Cli::V1::Service::Accounts è modulo per i tokens).
      class AccountsController < Cli::V1::BaseController
        before_action :require_manage
        before_action :set_account, only: %i[show update destroy]

        def index
          scope = Current.organization.accounts.service.includes(:api_tokens).order(:name)
          records, meta = paginate(scope)
          memberships = Current.organization.memberships
                               .where(account_id: records.map(&:id)).index_by(&:account_id)
          data = records.map { |account| serialize(account, memberships[account.id]) }
          render json: { data: data, meta: meta }
        end

        def show
          render json: { data: serialize(@account, membership_for(@account)) }
        end

        def create
          result = ::Accounts::Service::Create.call(
            organization: Current.organization,
            name: params[:name], handle: params[:handle],
            project_ids: params[:project_ids], group_ids: params[:group_ids], role_ids: params[:role_ids],
            grant_secrets: ActiveModel::Type::Boolean.new.cast(params[:grant_secrets]),
            secret_environment_codes: params[:secret_environment_codes],
            actor: Current.account
          )

          if result.ok?
            render json: { data: serialize(result.value, membership_for(result.value)) }, status: :created
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        # Aggiorna la restrizione degli environment sui secret (allow-list; vuoto = tutti). Sanificazione
        # anti-lockout ai soli code dell'org dentro Connections::SetSecretAccess (CYRA-78: punto di
        # scrittura unico coi canali umani). Gli override per-progetto si impostano dalla pagina accessi.
        def update
          membership = membership_for(@account)
          ::Connections::SetSecretAccess.call(membership: membership,
                                              org_wide_codes: params[:secret_environment_codes])
          render json: { data: serialize(@account, membership.reload) }
        end

        # "Elimina" = retire audit-safe (non distrugge l'account: preserva Secrets::Event.actor). Se il
        # retire fallisce/rollbacka NON rispondiamo 204 (token/accessi resterebbero attivi): errore envelope.
        def destroy
          result = ::Accounts::Service::Retire.call(account: @account, organization: Current.organization)
          return render_no_content if result.ok?

          render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
        end

        private

        def set_account
          @account = Current.organization.accounts.service.find(params[:id])
        end

        def membership_for(account)
          Current.organization.memberships.find_by(account: account)
        end

        def serialize(account, membership)
          ServiceAccountSerializer.new(account).as_json.merge(
            "secret_environment_codes" => membership&.secret_environment_codes || [],
            "active_tokens_count" => account.api_tokens.count { |token| !token.revoked? }
          )
        end

        def require_manage
          require_permission!("members.manage")
        end
      end
    end
  end
end
