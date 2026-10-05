# frozen_string_literal: true

module Member
  module Service
    # Service account (membri di tipo AI, non-umani, CLI-only): lista, creazione, dettaglio, eliminazione.
    # Gated members.manage. La creazione delega a ::Accounts::Service::Create (account + membership +
    # accesso). L'RBAC fine (ruoli/override/scope) si gestisce riusando /member/members/:id/access.
    # Model SEMPRE ::Accounts::* fully-qualified: Member::Service::Accounts esiste come modulo (tokens
    # nested) → un riferimento nudo `Accounts::` ombreggerebbe il dominio (anti-shadowing).
    class AccountsController < Member::BaseController
      before_action :require_manage
      before_action :set_account, only: %i[show update destroy]
      before_action :load_grantables, only: %i[new create]

      def index
        service_accounts = current_organization.accounts.service
        @pagination = paginate(sorted(service_accounts.includes(:api_tokens, :account_permissions).order(:name), columns: sort_columns))
        @accounts = @pagination.records
        @total_count = service_accounts.count
        @with_secrets_count = service_accounts
                              .joins(:account_permissions)
                              .where(authorization_account_permissions: {
                                       organization_id: current_organization.id,
                                       permission_key: "secrets.manage", effect: ::Authorization::AccountPermission.effects[:allow]
                                     }).distinct.count
      end

      def show
        load_account_detail
      end

      def new; end

      # Aggiorna la restrizione degli environment sui secret (allow-list; vuoto = tutti). Sanificazione
      # anti-lockout ai soli code dell'org dentro Connections::SetSecretAccess (CYRA-78: punto di
      # scrittura unico coi canali umani). Su un membership del service account nell'org corrente.
      def update
        membership = current_organization.memberships.find_by!(account: @account)
        ::Connections::SetSecretAccess.call(membership: membership,
                                            org_wide_codes: params[:secret_environment_codes])
        redirect_to member_service_account_path(@account), notice: t("member.service_accounts.updated")
      rescue ActiveRecord::RecordNotFound
        redirect_to member_service_accounts_path, alert: t("member.service_accounts.cannot_delete")
      end

      def create
        result = ::Accounts::Service::Create.call(
          organization: current_organization,
          name: params[:name],
          handle: params[:handle],
          project_ids: params[:project_ids],
          group_ids: params[:group_ids],
          role_ids: params[:role_ids],
          grant_secrets: ActiveModel::Type::Boolean.new.cast(params[:grant_secrets]),
          secret_environment_codes: params[:secret_environment_codes],
          actor: Current.account,
          true_actor: Current.true_account
        )

        if result.ok?
          redirect_to member_service_account_path(result.value), notice: t("member.service_accounts.created")
        else
          @errors = result.error.details.presence || { base: [ result.error.message ] }
          render :new, status: :unprocessable_content
        end
      end

      # "Elimina" = retire audit-safe: NON distrugge l'account (nullifierebbe Secrets::Event.actor), ma
      # revoca i token + rimuove accesso/membership → sparisce dalla lista, l'audit dei secret resta.
      def destroy
        result = ::Accounts::Service::Retire.call(account: @account, organization: current_organization)
        if result.ok?
          redirect_to member_service_accounts_path, notice: t("member.service_accounts.deleted")
        else
          redirect_to member_service_account_path(@account), alert: t("member.service_accounts.cannot_delete")
        end
      end

      private

      # CYRA-924 — every column but the actions sorts (C9). Secrets = may manage them here.
      def sort_columns
        secrets = ::Accounts::Account.sanitize_sql_array(
          [ "EXISTS (SELECT 1 FROM authorization_account_permissions p WHERE p.account_id = accounts.id " \
            "AND p.organization_id = ? AND p.permission_key = 'secrets.manage' AND p.effect = ?)",
            current_organization.id, ::Authorization::AccountPermission.effects[:allow] ]
        )
        {
          "name" => "LOWER(accounts.name)",
          "handle" => "LOWER(accounts.handle)",
          "secrets" => secrets,
          "tokens" => "(SELECT COUNT(*) FROM accounts_api_tokens t WHERE t.account_id = accounts.id AND t.revoked_at IS NULL)"
        }
      end

      # Anti-BOLA: solo i service account dell'org corrente; un account umano o di un'altra org → 404.
      def set_account
        @account = current_organization.accounts.service.find(params[:id])
      end

      def load_account_detail
        @membership = current_organization.memberships.find_by(account: @account)
        @secret_environment_codes = @membership&.secret_environment_codes || []
        @grantable_environments = current_organization.environments.order(:code).to_a
        @tokens = @account.api_tokens.where(organization: current_organization)
                          .order(revoked_at: :asc, created_at: :desc)
        @visible_projects = @account.directly_accessible_projects.where(organization: current_organization).order(:name)
        @roles = @account.assigned_roles.where(organization: current_organization).order(:name)
        @grants = @account.account_permissions.where(organization: current_organization).order(:permission_key)
      end

      def load_grantables
        @grantable_projects = current_organization.projects.order(:name).to_a
        @grantable_groups = current_organization.groups.order(:name).to_a
        @grantable_roles = current_organization.roles.ordered.to_a
        @grantable_environments = current_organization.environments.order(:code).to_a
      end

      def require_manage
        require_permission!("members.manage")
      end
    end
  end
end
