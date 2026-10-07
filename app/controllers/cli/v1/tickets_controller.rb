# frozen_string_literal: true

module Cli
  module V1
    # Ticket del progetto: lettura + ciclo di vita. Aprire un ticket è baseline (chi vede il progetto può);
    # Ticketing::CreateTicket ri-verifica la visibilità (R404-TICKET-001) e isola org/scope (anti-BOLA).
    # Mutazioni gated per-azione: update (`tickets.edit`), destroy (`tickets.delete`), scope = progetto del path.
    # La logica vive nei service Ticketing::{Create,Update}Ticket, condivisa col canale Member
    # (`rules/backend-channels.md`): qui solo auth/gate/serializzazione del canale CLI.
    class TicketsController < Cli::V1::BaseController
      include AiEnqueueing

      before_action :set_project!, except: :ask
      before_action :set_ticket, only: %i[show update destroy]

      def index
        # includes speculare agli attributi del serializer (status/priority/persone/milestone/platforms):
        # senza, la lista paginata fa N+1 per riga.
        scope = @project.tickets
                        .includes(:status, :priority, :assignee, :reporter, :reviewer, :milestone, :platforms,
                                  :scenarios, :conditions)
                        .order(created_at: :desc)
        # Filtro opzionale sul gate agenti (CYRA-184): serve a rispondere a "cosa devo ancora
        # esaminare?" senza scorrere l'intero backlog. Valori fuori enum → ArgumentError gestito
        # come 422 dal base controller, mai una lista silenziosamente vuota.
        if params[:agent_eligibility].present?
          scope = scope.where(agent_eligibility: Array(params[:agent_eligibility]))
        end
        records, meta = paginate(scope)
        # blocked/workable senza N+1: UN Set aggregato per l'intera pagina (mai un blocked? per riga).
        blocked_ids = Connections::TicketDependency.blocked_ids_among(records.map(&:id))
        render_ok(TicketSerializer.new(records, params: { blocked_ids: blocked_ids }), meta: meta)
      end

      def show
        # Il dettaglio è il canale d'analisi: espone anche la guidance risolta del progetto (CYRA-74),
        # pre-calcolata qui e passata via params così la serializzazione non fa query extra.
        guidance = ::Guidance::Resolve.call(project: @ticket.project)
        answered = @ticket.questions.readable_by(Current.account, organization: Current.organization)
        render_ok(TicketSerializer.new(@ticket, params: { guidance: guidance, answered_questions: answered }))
      end

      def create
        result = Ticketing::CreateTicket.call(
          organization: Current.organization,
          reporter: Current.account,
          true_actor: Current.account,
          params: ticket_params
        )
        if result.ok?
          render_created(TicketSerializer.new(result.value))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def update
        return unless require_permission!("tickets.edit", scope: @project)

        result = Ticketing::UpdateTicket.call(
          channel: :cli,
          organization: Current.organization, ticket: @ticket, params: ticket_params,
          actor: Current.account, true_actor: Current.account
        )
        if result.ok?
          render_ok(TicketSerializer.new(@ticket))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        return unless require_permission!("tickets.delete", scope: @project)

        @ticket.destroy
        render_no_content
      end

      # "Chiedi ai ticket" (RAG) dal terminale: gemello CLI di Member::TicketsController#ask_query.
      # CROSS-progetto — è la sola azione del controller senza un progetto nel path — quindi
      # set_project! qui non si applica e lo scope è l'intero perimetro visibile al token.
      #
      # Asincrono come il web: accoda Ai::RunJob e risponde 202 con request_id, che si segue su
      # GET /cli/v1/ai/requests/:id. I project_ids si congelano all'enqueue e il job parte da lì
      # invece di ricalcolarne una di un altro momento — ma è un TETTO, non un lasciapassare
      # (CYRA-812): il job li interseca col perimetro di allora prima di leggere.
      def ask
        question = params[:question].to_s
        if question.strip.blank?
          return render_error("R422-TICKET-005", I18n.t("member.tickets.ask.errors.blank"),
                              status: :unprocessable_content)
        end

        enqueue_ai_request!(kind: "ticket_ask", args: { question: }.merge(ai_scope_args))
      end

      private

      # Anti-BOLA: il ticket si risolve DENTRO @project (già ristretto a visible_projects da set_project!);
      # un ticket di un altro progetto/org → RecordNotFound → R404 (mai 403, mai leak cross-tenant).
      # Accetta UUID o code umano ("DRFL-3") via find_ticket! (Cli::V1::BaseController).
      def set_ticket
        @ticket = find_ticket!(@project, params[:id])
      end

      def ticket_params
        params.permit(:title, :kind, :description, :technical_analysis, :weight, :due_at,
                      :status_id, :priority_id, :assignee_id, :milestone_id, :parent_id, platform_ids: [],
                      scenarios_attributes: %i[id title position step_given step_when step_then step_expected _destroy],
                      conditions_attributes: %i[id text position _destroy])
              .merge(project_id: @project.id)
      end
    end
  end
end
