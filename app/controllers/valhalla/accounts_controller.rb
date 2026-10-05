# frozen_string_literal: true

module Valhalla
  class AccountsController < BaseController
    # Whitelist ordinamento (contratto Sortable#sorted). Org e Role restano statici:
    # derivano dalla prima membership, non da una colonna dell'account.
    SORT_COLUMNS = {
      "account" => "LOWER(accounts.name)",
      "email" => "LOWER(accounts.email)",
      "created" => :created_at
    }.freeze

    before_action :set_account, only: %i[edit update destroy toggle_god reset_password]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :role, :q, :sort, only: :index

    def index
      scope = Accounts::Account.includes(memberships: :organization).order(created_at: :desc)
      scope = scope.where("accounts.email ILIKE :q OR accounts.name ILIKE :q", q: "%#{search_q}%") if search_q.present?
      if filter_ids(:role).any?
        # Subselect (niente joins+distinct): con includes(memberships:) il join duplicherebbe
        # le righe, e DISTINCT + ORDER BY su espressione fuori dalla select è errore PG.
        scope = scope.where(id: Connections::Membership.where(role: filter_ids(:role)).select(:account_id))
      end
      @pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
      @accounts = @pagination.records
    end

    def new
      @account = Accounts::Account.new
      @errors = {}
    end

    def create
      @account = Accounts::Account.new(create_params)

      if self_password?
        temporary = generated_password
        @account.password = temporary
        @account.password_confirmation = temporary
      end

      if @account.save
        Auth::PasswordsMailer.reset(@account).deliver_later if self_password?
        broadcast_prepend
        redirect_to valhalla_accounts_path, notice: t("valhalla.accounts.created")
      else
        @errors = @account.errors.to_hash
        flash.now[:alert] = t("valhalla.accounts.failed")
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @errors = {}
    end

    def update
      if @account.update(update_params)
        broadcast_replace
        redirect_to valhalla_accounts_path, notice: t("valhalla.accounts.updated")
      else
        @errors = @account.errors.to_hash
        flash.now[:alert] = t("valhalla.accounts.failed")
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      return redirect_to(valhalla_accounts_path, alert: t("valhalla.accounts.cannot_self")) if self_target?

      # destroy ritorna false se un dependent: :restrict_with_error blocca (es. ticket segnalati):
      # gestire il false (niente broadcast/redirect-"eliminato" che mentirebbe). Il rescue è una
      # rete di sicurezza per eventuali FK RESTRICT residue → alert pulito invece di 500.
      if @account.destroy
        broadcast_remove
        redirect_to valhalla_accounts_path, notice: t("valhalla.accounts.deleted")
      else
        redirect_to valhalla_accounts_path, alert: t("valhalla.accounts.cannot_delete")
      end
    rescue ActiveRecord::InvalidForeignKey
      redirect_to valhalla_accounts_path, alert: t("valhalla.accounts.cannot_delete")
    end

    def toggle_god
      return redirect_to(valhalla_accounts_path, alert: t("valhalla.accounts.cannot_self")) if self_target?

      @account.update!(god: !@account.god?)
      broadcast_replace
      redirect_to valhalla_accounts_path, notice: t("valhalla.accounts.god_toggled")
    end

    def reset_password
      Auth::PasswordsMailer.reset(@account).deliver_later
      redirect_to valhalla_accounts_path, notice: t("valhalla.accounts.reset_sent")
    end

    private

    def set_account
      @account = Accounts::Account.find(params[:id])
    end

    def create_params
      params.permit(:name, :email, :password, :password_confirmation, :god)
    end

    def update_params
      params.permit(:name, :email, :god)
    end

    def self_password?
      ActiveModel::Type::Boolean.new.cast(params[:self_password])
    end

    def self_target?
      @account == Current.account
    end

    # Password temporanea conforme alla policy (4 classi): l'utente la sostituisce dal link di setup.
    def generated_password
      "#{SecureRandom.alphanumeric(16)}Aa1!"
    end

    # Aggiornamenti live multi-client via Turbo Stream broadcasts (Action Cable / Solid Cable).
    def broadcast_prepend
      Turbo::StreamsChannel.broadcast_prepend_to(
        "valhalla_accounts", target: "valhalla_accounts",
        partial: "valhalla/accounts/account", locals: { account: @account }
      )
    end

    def broadcast_replace
      Turbo::StreamsChannel.broadcast_replace_to(
        "valhalla_accounts", target: ActionView::RecordIdentifier.dom_id(@account),
        partial: "valhalla/accounts/account", locals: { account: @account }
      )
    end

    def broadcast_remove
      Turbo::StreamsChannel.broadcast_remove_to(
        "valhalla_accounts", target: ActionView::RecordIdentifier.dom_id(@account)
      )
    end
  end
end
