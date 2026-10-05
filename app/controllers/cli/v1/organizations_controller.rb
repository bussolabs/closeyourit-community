# frozen_string_literal: true

module Cli
  module V1
    # Impostazioni dell'organizzazione del token (SINGLETON). Si opera SEMPRE su Current.organization
    # (il token pinna l'org) → nessun id esterno, nessun BOLA. show E update gated da `organization.manage`
    # (org-level), come il canale Member che espone le impostazioni org solo all'owner (l'identità
    # dell'org — id/name/slug — resta comunque leggibile da qualsiasi token via whoami). STESSI params.
    class OrganizationsController < Cli::V1::BaseController
      before_action :require_org_management, only: %i[show update]

      def show
        render_ok(OrganizationSerializer.new(Current.organization))
      end

      def update
        if Current.organization.update(organization_params)
          render_ok(OrganizationSerializer.new(Current.organization))
        else
          render_error("R422-ORGANIZATION-001", Current.organization.errors.full_messages.to_sentence,
                       status: :unprocessable_content, details: Current.organization.errors.to_hash)
        end
      end

      private

      # Stessi campi del canale Member (Member::OrganizationsController): anagrafica + retention org-level
      # (log/analytics; blank = eredita il default god). La validazione dei range vive sul model.
      # `default_space` non è più fra i permessi (CYRA-521): un client che continua a mandarlo non riceve
      # errore, il valore viene semplicemente scartato come qualsiasi parametro non dichiarato. La
      # rimozione dal payload di risposta segue col prossimo bump — vedi OrganizationSerializer.
      def organization_params
        params.permit(:name, :slug, :default_projects_view, :logs_retention_days, :analytics_retention_days,
                      :errors_retention_days, :performance_retention_days, :servers_retention_days,
                      :uptime_retention_days, :traces_retention_days, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days)
      end

      def require_org_management
        require_permission!("organization.manage")
      end
    end
  end
end
