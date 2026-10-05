# frozen_string_literal: true

module Cli
  module V1
    module Vault
      # Richieste di modifica ai secret in attesa dell'approvazione a due, dal canale CLI (CYRA-230).
      # Speculare a Member::Vault::ChangeRequestsController: elenco org-wide via
      # Secrets::ChangeRequests::Pending (anti-disclosure: gestore del progetto O richiedente), decisione
      # via i service Approve/Reject col vincolo 4-eyes. Anti-BOLA: la CR è risolta nei progetti VISIBILI
      # (fuori scope/altra org → R404 PRIMA del gate secrets.manage).
      class ChangeRequestsController < Cli::V1::BaseController
        before_action :set_change_request!, only: %i[approve reject]
        before_action :require_manage!, only: %i[approve reject]

        # GET .../vault/change_requests — le pending visibili all'account sui progetti dell'org (lo STESSO
        # elenco della pagina web: identico servizio Pending).
        def index
          pending = ::Secrets::ChangeRequests::Pending.new(account: Current.account, projects: visible_projects)
          render_ok(SecretChangeRequestSerializer.new(pending.requests))
        end

        # POST .../vault/change_requests/:id/approve — applica la modifica decisa (il service ri-applica
        # il 4-eyes: chi approva non può essere chi ha chiesto).
        def approve
          result = ::Secrets::ChangeRequests::Approve.call(change_request: @change_request, actor: Current.account)
          render_decision(result)
        end

        # POST .../vault/change_requests/:id/reject — congela come rejected (reason obbligatoria), il
        # secret non cambia.
        def reject
          result = ::Secrets::ChangeRequests::Reject.call(
            change_request: @change_request, actor: Current.account, reason: params[:reason]
          )
          render_decision(result)
        end

        private

        # Anti-BOLA: la CR dev'essere di un progetto VISIBILE all'account (fuori scope/altra org →
        # RecordNotFound → R404), come set_change_request nel canale web.
        def set_change_request!
          @change_request = ::Secrets::ChangeRequest.where(project_id: visible_projects.select(:id)).find(params[:id])
        end

        # approve/reject: gate secrets.manage sul progetto della CR. set_change_request! gira prima →
        # il 404 anti-BOLA precede il 403, come altrove nel canale CLI.
        def require_manage!
          require_permission!("secrets.manage", scope: @change_request.project)
        end

        def render_decision(result)
          return render_ok(SecretChangeRequestSerializer.new(result.value)) if result.ok?

          render_error(result.error.code, result.error.message, status: result.error.status)
        end
      end
    end
  end
end
