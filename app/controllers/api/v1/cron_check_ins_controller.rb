# frozen_string_literal: true

module Api
  module V1
    # Heartbeat check-in di un job schedulato (token bearer per-progetto). Il monitor nasce al primo
    # check-in (upsert per slug). Body opzionale: status (ok/fail), duration_ms, reason, name,
    # expected_interval_minutes, grace_minutes, environment. Envelope {data}/{error}.
    class CronCheckInsController < Api::V1::BaseController
      include AutomatorAuthentication

      # Due autorità distinte sullo stesso endpoint (CYRA-182):
      #  - token ingest di progetto (cyi_t_): il caso storico, invariato, con scope 'ingest' richiesto;
      #  - token Agent Host (cyi_ah_): il daemon Automator batte con la PROPRIA credenziale revocabile.
      # Il token host non è un Projects::Token, quindi l'autenticazione bearer standard lo rifiutava con
      # 401 e ogni battito si perdeva in silenzio (heartbeat best-effort lato client): host offline per
      # sempre, nessuna traccia nei log. Lo scope 'ingest' resta richiesto SOLO al token di progetto:
      # un token host non porta scope di progetto, la sua autorità è l'identità host stessa.
      skip_before_action :authenticate_token!
      before_action :authenticate_check_in!
      before_action -> { require_scope!(:ingest) }, unless: :host_bearer?

      def create
        at = Time.current
        result = record_check_in_atomically(at:)
        if result.ok?
          render json: { data: { slug: result.value.slug, status: result.value.status } }, status: :accepted
        else
          render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
        end
      end

      private

      # Il bearer presentato è un token Agent Host? Risolto una sola volta per richiesta: decide sia il
      # ramo di autenticazione sia se pretendere lo scope 'ingest'.
      def host_bearer?
        return @host_bearer if defined?(@host_bearer)

        @host_bearer = ::Agents::HostToken.active.exists?(token_digest: presented_automator_digest)
      end

      def authenticate_check_in!
        return authenticate_token! unless host_bearer?

        authenticate_automator_host!
        return if performed? # host o token revocato → 401 già reso

        # Anti-BOLA: il progetto della rotta deve appartenere all'organizzazione dell'host. Il 404 nudo
        # è lo stesso di enforce_project_scope! per il token di progetto — non rivela l'esistenza altrui.
        project = Current.organization.projects.find_by(id: params[:project_id])
        return head :not_found if project.nil?

        Current.project = project
      end

      # Heartbeat host e check-in cron rappresentano lo stesso evento ingest: un errore in uno dei due
      # rami deve lasciare entrambi invariati, incluso il binding iniziale host→progetto.
      def record_check_in_atomically(at:)
        result = nil
        ApplicationRecord.transaction do
          result = Crons::RecordCheckIn.call(
            project: Current.project, slug: params[:slug],
            status: params[:status], duration_ms: params[:duration_ms], reason: params[:reason],
            name: params[:name],
            expected_interval_minutes: params[:expected_interval_minutes],
            grace_minutes: params[:grace_minutes], environment: params[:environment], at:
          )
          raise ActiveRecord::Rollback if result.err?

          heartbeat_result = record_host_heartbeat(at:, monitor: result.value)
          if heartbeat_result.err?
            result = heartbeat_result
            raise ActiveRecord::Rollback
          end
        end
        result
      end

      # Heartbeat cron legacy (senza host_id) invariato. Se l'identità è presente, il lookup resta
      # tenant-scoped all'organizzazione già autenticata dal token del progetto.
      def record_host_heartbeat(at:, monitor:)
        # Quando l'autenticazione è host-bound l'identità viene dal TOKEN, non dal body: un host_id
        # ostile non può dirottare la telemetria (né il last_heartbeat_at) su un'altra macchina della
        # stessa organizzazione. Col token di progetto resta l'host_id dichiarato, come prima.
        host_id = Current.agent_host&.id || params[:host_id]
        return Result.ok if host_id.blank?

        payload = host_telemetry_params.to_h.merge(
          "host_id" => host_id,
          "expected_interval_minutes" => monitor.expected_interval_minutes,
          "grace_minutes" => monitor.grace_minutes
        )
        ::Agents::Hosts::RecordHeartbeat.call(project: Current.project, payload:, at:)
      end

      # Allowlist ricorsiva: path locali, token, secret e campi futuri/sconosciuti non raggiungono il service.
      def host_telemetry_params
        params.permit(
          :host_id, :automator_version, :platform, :arch, :running, :slots, :host_status,
          :expected_interval_minutes, :grace_minutes,
          repositories: [],
          runtimes: %i[name present version required],
          active_runs: %i[
            ticket run_id phase runtime started_at updated_at lease_expires_at lease_health stalled
          ],
          last_stops: %i[action state reason]
        )
      end
    end
  end
end
