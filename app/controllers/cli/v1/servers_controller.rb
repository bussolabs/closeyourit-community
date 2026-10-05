# frozen_string_literal: true

module Cli
  module V1
    # Flotta server monitoring (org-level) dell'organizzazione del token. A differenza delle regole
    # alerting anche la LETTURA è gated (servers.view, manage-implies-view — come la UI Member).
    # Mutazioni (rename/pause/resume/revoke/unrevoke/destroy) gated da servers.manage. Anti-BOLA:
    # scope org via Current.organization.server_hosts → un id di un'altra org dà R404.
    class ServersController < Cli::V1::BaseController
      before_action :require_view
      before_action :set_host, only: %i[show update destroy pause resume revoke unrevoke]
      before_action :require_manage, only: %i[update destroy pause resume revoke unrevoke]

      def index
        scope = Current.organization.server_hosts.ordered
        scope = scope.where(status: status_filter) if status_filter.any?
        records, meta = paginate(scope)
        render_ok(HostSerializer.new(records), meta: meta)
      end

      def show
        render_ok(HostSerializer.new(@host))
      end

      def update
        if @host.update(host_params)
          render_ok(HostSerializer.new(@host))
        else
          render_error("R422-SERVER-005", @host.errors.full_messages.to_sentence,
                       status: :unprocessable_content, details: @host.errors.to_hash)
        end
      end

      def destroy
        @host.destroy
        render_no_content
      end

      # Stesse transizioni inline della UI Member: pause = fuori da staleness/alert;
      # resume → pending (torna up al primo push, senza fingere salute).
      def pause  = transition(status: :paused)
      def resume = transition(status: :pending)

      # Revoca: l'agent riceve 403 e si ferma; l'host resta (niente re-registrazione fantasma).
      def revoke   = transition(revoked_at: Time.current)
      def unrevoke = transition(revoked_at: nil)

      private

      def transition(attrs)
        @host.update!(attrs)
        render_ok(HostSerializer.new(@host))
      end

      # CYRA-519 — i nomi che su questa macchina non sono servizi si scrivevano solo dalla pagina web:
      # chi lavora da terminale non aveva modo di sistemare una lista di due righe. Si accetta sia un
      # elenco sia una riga sola (la normalizzazione del model spezza su virgole e a capo).
      #
      # Solo le chiavi ARRIVATE finiscono nell'update: un aggiornamento parziale non azzera il resto
      # — è il punto che il ticket chiedeva di verificare, e la spec lo tiene fermo.
      def host_params
        attrs = params.permit(:name).to_h
        return attrs unless params.key?(:ignored_container_patterns)

        raw = params[:ignored_container_patterns]
        attrs[:ignored_container_patterns] = Array(raw).map(&:to_s)
        attrs
      end

      # Anti-BOLA: solo host della propria org (id di un'altra org → RecordNotFound → R404).
      def set_host
        @host = Current.organization.server_hosts.find(params[:id])
      end

      def require_view
        return true if authorization.can?("servers.view") || authorization.can?("servers.manage")

        render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
        false
      end

      def require_manage
        require_permission!("servers.manage")
      end

      def status_filter = Array(params[:status]).reject(&:blank?) & ::Servers::Host.statuses.keys
    end
  end
end
