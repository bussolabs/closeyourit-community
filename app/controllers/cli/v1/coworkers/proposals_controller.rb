# frozen_string_literal: true

module Cli
  module V1
    module Coworkers
      # Confirm or discard an action a Puck proposed, from the apps (CYRA-1022). Same checks as the web.
      class ProposalsController < Cli::V1::BaseController
        include CoworkerApi

        def confirm
          proposal = load_proposal
          outcome = ::Assistant::Proposals::Confirm.call(proposal: proposal, account: Current.account, organization: Current.organization,
                                                         allowed_project_ids: ::Coworkers::Scope.snapshot(proposal.coworkers_run).project_ids)
          return render_error(outcome.error.code, outcome.error.message, status: :unprocessable_content) if outcome.err?

          render_ok({ id: proposal.id, status: proposal.reload.status })
        end

        def discard
          proposal = load_proposal
          proposal.update!(status: :discarded) if proposal.confirmable?
          render_ok({ id: proposal.id, status: proposal.status })
        end

        private

        def load_proposal
          ::Assistant::Proposal.where(coworkers_run_id: coworker_puck.runs.select(:id), account_id: Current.account.id).find(params[:id])
        end
      end
    end
  end
end
