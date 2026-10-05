# frozen_string_literal: true

module Member
  module Monitoring
    # Enrollment token della flotta (universale org-scoped, per gli agent). Lista + creazione con
    # reveal-once del segreto + revoca. Gated da servers.manage. Pattern Member::ProjectTokensController.
    class ServerTokensController < Member::BaseController
      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      # Whitelist ordinamento (contratto Sortable#sorted). status = revoked_at (attivi in
      # fondo via NULLS LAST).
      SORT_COLUMNS = {
        "name" => "LOWER(servers_enrollment_tokens.name)",
        "prefix" => :token_prefix,
        "last_used" => :last_used_at,
        "status" => :revoked_at
      }.freeze

      before_action :require_manage

      def index
        # CYRA-459 — quante macchine hanno davvero mandato qualcosa: è la risposta a "ha funzionato?".
        @servers_count = visible.servers.count
        load_tokens
      end

      def create
        result = ::Servers::EnrollmentTokens::Issue.call(
          organization: Current.organization,
          name: params[:name],
          created_by: Current.account
        )

        if result.ok?
          # Reveal-once: il segreto è mostrato UNA sola volta, qui, senza finire in DB né in sessione.
          @revealed = result.value
          load_tokens
          render :index, status: :created
        else
          @errors = result.error.details || { base: [ result.error.message ] }
          load_tokens
          render :index, status: :unprocessable_content
        end
      end

      def destroy
        token = Current.organization.server_enrollment_tokens.find(params[:id])
        # CYRA-469 — è l'azione dal raggio più ampio del prodotto: revocare un codice non deve
        # riuscire con un clic distratto. Chi revoca deve aver DIGITATO il nome del codice; senza la
        # conferma esatta non tocchiamo niente. Il gate vive qui, lato server, non solo in pagina:
        # così vale anche se qualcuno salta l'interfaccia.
        unless params[:confirm].to_s.strip == token.name
          return redirect_to member_monitoring_server_tokens_path,
                             alert: t("member.servers.tokens.revoke_denied")
        end

        affected = token.hosts.active.count
        ::Servers::EnrollmentTokens::Revoke.call(token: token)
        redirect_to member_monitoring_server_tokens_path,
                    notice: t("member.servers.tokens.revoked", count: affected)
      end

      private

      def load_tokens
        scope = Current.organization.server_enrollment_tokens.order(revoked_at: :asc, created_at: :desc)
        @tokens = paginated(scope, columns: SORT_COLUMNS)
        @active_tokens_count = Current.organization.server_enrollment_tokens.active.count
        @revoked_tokens_count = Current.organization.server_enrollment_tokens.count - @active_tokens_count
        # CYRA-469 — quante macchine sono collegate a CIASCUN codice: il conteggio che la pagina non
        # dava. Una sola query aggregata (niente N+1), letta in view come @hosts_by_token[id]. Vive in
        # load_tokens perché la index è renderizzata anche da create (ok/errore), non solo da #index.
        @hosts_by_token = Current.organization.server_hosts.active
                                 .where.not(enrollment_token_id: nil)
                                 .group(:enrollment_token_id).count
      end

      def require_manage
        require_permission!("servers.manage")
      end
    end
  end
end
