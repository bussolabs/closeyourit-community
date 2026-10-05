# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Dipendenze (prerequisiti) tra ticket sul canale CLI (CYRA-83): il ticket A DIPENDE dal blocker B.
      # Clone di Cli::V1::Tickets::LinksController con in più la create, gemello del web
      # Member::Tickets::DependenciesController. index è baseline (chi vede il ticket); create/destroy
      # sono gated tickets.edit come 403 REALE. La logica (confine tenant, snapshot, evento, anti-ciclo,
      # lock) vive nei service condivisi col web Ticketing::AddDependency/RemoveDependency: nessuna
      # logica duplicata (rules/backend-channels.md), stessi codici errore del canale Member.
      #
      # Anti-BOLA su 4 casi → tutti 404 senza leak: (1) ticket A in un progetto non visibile → set_project!
      # /set_ticket; (2) blocker non visibile e (3) blocker di altra org/progetto → AddDependency cerca
      # solo tra visible_tickets → R404-TICKET-015; (4) dependency UUID di un altro ticket → RemoveDependency
      # risale via @ticket.dependencies → R404-TICKET-016. Lo scope si risolve PRIMA del gate: un progetto
      # invisibile dà 404 prima del 403.
      class DependenciesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def index
          # includes speculare al serializer (blocker→status): senza, ogni voce fa N+1 su code/title/status.
          # Il progetto del blocker serve al CODICE del ticket, che è chiave di progetto + numero
          # (CYRA-747): senza, il codice è una query per voce.
          dependencies = @ticket.dependencies.includes(blocker: %i[status project]).order(created_at: :desc).to_a
          # Anti-BOLA in lettura: un blocker cross-project può stare in un progetto non visibile a chi
          # guarda A → il serializer ne oscura identità (blocker_id/code/title), tiene solo lo stato.
          # Set dei blocker visibili con UNA pluck (parità col web, mai un check per riga).
          visible_blocker_ids = visible_tickets.where(id: dependencies.map(&:blocker_id)).pluck(:id).to_set
          render_ok(TicketDependencySerializer.new(dependencies, params: { visible_blocker_ids: visible_blocker_ids }))
        end

        def create
          return unless require_permission!("tickets.edit", scope: @project)

          result = Ticketing::AddDependency.call(
            ticket: @ticket, blocker_id: resolve_blocker_id(params[:blocker]),
            visible_tickets: visible_tickets,
            actor: Current.account, true_actor: Current.account
          )
          if result.ok?
            # Il blocker è appena stato validato tra i visibili dal service → mostrato per intero.
            render_created(TicketDependencySerializer.new(result.value,
                                                          params: { visible_blocker_ids: Set[result.value.blocker_id] }))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          return unless require_permission!("tickets.edit", scope: @project)

          result = Ticketing::RemoveDependency.call(
            ticket: @ticket, dependency_id: params[:id],
            actor: Current.account, true_actor: Current.account
          )
          if result.ok?
            render_no_content
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        private

        # Anti-BOLA: A si risolve dentro @project (già ristretto a visible_projects); UUID o KEY-N.
        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        # Il blocker può stare in un ALTRO progetto visibile (dipendenza cross-project intra-org): lo
        # risolvo tra TUTTI i ticket visibili per UUID o code umano ("DRFL-3"), scoped prima dell'authz.
        # Fuori scope → nil, e AddDependency traduce in R404-TICKET-015 (nessun leak). L'UUID risolto è
        # comunque ri-validato dentro visible_tickets dal service, che resta la guardia autoritativa.
        def resolve_blocker_id(ref)
          find_visible_ticket(ref)&.id
        end
      end
    end
  end
end
