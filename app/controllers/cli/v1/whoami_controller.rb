# frozen_string_literal: true

module Cli
  module V1
    # Identità del token: account, org di contesto, token corrente e permessi org-level effettivi
    # (god/owner → tutti). I permessi scoped per-progetto si verificano sui singoli endpoint.
    class WhoamiController < Cli::V1::BaseController
      def show
        render_ok({
          account: AccountSerializer.new(Current.account).as_json,
          organization: {
            id: Current.organization.id,
            name: Current.organization.name,
            slug: Current.organization.slug
          },
          # CYRA-717 — la scadenza arriva già masticata: data, giorni residui e stato. La riga di
          # comando deve poter avvisare («scade fra 3 giorni») senza rifare i conti sul fuso.
          token: {
            id: Current.api_token.id,
            name: Current.api_token.name,
            prefix: Current.api_token.token_prefix,
            expires_at: Current.api_token.expires_at,
            expires_in_days: Current.api_token.days_until_expiry,
            expiry_status: Current.api_token.expiry_status
          },
          permissions: Authorization::Catalog.keys.select { |key| authorization.can?(key) }
        })
      end
    end
  end
end
