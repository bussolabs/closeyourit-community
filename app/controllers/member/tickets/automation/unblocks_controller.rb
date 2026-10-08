# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      # Riprova una lavorazione fermata dal tetto ai tentativi di revisione (CYRA-218). Gemello degli
      # altri gate: stessa forma, stessa autorizzazione (CTO effettivo, dentro il service).
      class UnblocksController < BaseController
        # CYRA-1057 — the only accepted value: a retry pressed on the approvals board goes back there.
        APPROVALS_RETURN = "approvals"

        def create
          workflow = workflow_for(params[:ticket_id])
          result = ::Agents::Workflows::Unblock.call(workflow:, actor: Current.account)
          return redirect_to_automation(workflow.ticket, result, "member.tickets.automation.blocked.retried") unless from_approvals?
          return row_outcome(result) if request.format.turbo_stream?

          redirect_to member_home_approvals_path,
                      result.ok? ? { notice: t("member.tickets.automation.blocked.retried") } : { alert: result.error.message }
        end

        private

        def from_approvals? = params[:return_to].to_s == APPROVALS_RETURN

        # CYRA-1059 — the board retries without reloading: the answer removes the row it came from.
        def row_outcome(result)
          flash.now[:notice] = t("member.tickets.automation.blocked.retried") if result.ok?
          flash.now[:alert] = result.error.message if result.err?
          row = params[:row].to_s[Member::ApprovalsBoardHelper::ROW_KEY]
          render "member/home/approvals/row_outcome", locals: { keys: (result.ok? && row ? [ row ] : []) },
                                                      status: (result.ok? ? :ok : :unprocessable_content)
        end
      end
    end
  end
end
