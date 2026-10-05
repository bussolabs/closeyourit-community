# frozen_string_literal: true

module Account
  module Cli
    # Configurazione dei propri token CLI (cross-org): lista + revoca. Eredita da ApplicationController
    # (login richiesto, nessun contesto org: un token vive in un'org sola, la lista le attraversa tutte).
    class TokensController < ApplicationController
      include Listable
      include Localizable

      # Whitelist ordinamento (contratto Sortable#sorted). status = revoked_at (attivi in
      # fondo via NULLS LAST); organization via join. Pagina senza toolbar/paginazione:
      # i link di ordinamento bastano.
      SORT_COLUMNS = {
        "name" => "LOWER(accounts_api_tokens.name)",
        "organization" => { expr: "LOWER(organizations.name)", joins: :organization },
        "prefix" => :token_prefix,
        "last_used" => :last_used_at,
        # CYRA-717 — chi ha una manciata di token vuole sapere QUALE scade per primo. NULLS LAST è
        # già il default di Postgres in ASC: i perpetui restano in fondo, dove non disturbano.
        "expiry" => :expires_at,
        "status" => :revoked_at
      }.freeze

      layout "account"

      def index
        # Attivi in testa: in ASC Postgres mette i NULL (i non revocati) in fondo.
        scope = Current.account.api_tokens.includes(:organization)
                       .order(Arel.sql("accounts_api_tokens.revoked_at IS NOT NULL"), created_at: :desc)
        @tokens = sorted(scope, columns: SORT_COLUMNS).to_a
      end

      def destroy
        token = Current.account.api_tokens.find(params[:id])
        Accounts::ApiTokens::Revoke.call(token:)
        redirect_to account_cli_tokens_path, notice: t("account.cli_tokens.revoked")
      end
    end
  end
end
