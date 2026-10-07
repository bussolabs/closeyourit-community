# frozen_string_literal: true

module Cli
  module V1
    module Coworkers
      # The conversation of a Puck for the apps: list, send a message, follow its answer (CYRA-1022).
      class RunsController < Cli::V1::BaseController
        include CoworkerApi
        PAGE = 20

        def index
          runs = coworker_puck.runs.includes(:action_proposals).order(created_at: :desc).limit(PAGE).to_a
          render_ok(CoworkerRunSerializer.new(runs))
        end

        def show
          render_ok(CoworkerRunSerializer.new(coworker_puck.runs.includes(:action_proposals).find(params[:id])))
        end

        def create
          run = ::Coworkers::Start.call(puck: coworker_puck, kind: params[:kind].presence_in(%w[chat task]) || "chat",
                                        input: params[:input], account: Current.account, channel: "app")
          render json: { data: CoworkerRunSerializer.new(run).to_h }, status: :accepted
        rescue ::Coworkers::Start::Busy
          render_error("R409-COWORKERS-002", "The Puck is busy", status: :conflict)
        rescue ::Coworkers::Start::OverBudget
          render_error("R409-COWORKERS-003", "The monthly ceiling is reached", status: :conflict)
        rescue ActiveRecord::RecordInvalid
          render_error("R422-COWORKERS-003", "Invalid message", status: :unprocessable_content)
        end

        def update
          run = coworker_puck.runs.find(params[:id])
          return render_error("R404-COWORKERS-002", "Run not found", status: :not_found) unless
            run.requester == Current.account || coworker_puck.managed_by?(Current.account)

          run.request_stop!
          render_ok(CoworkerRunSerializer.new(run.reload))
        end
      end
    end
  end
end
