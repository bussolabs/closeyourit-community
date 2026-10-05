# frozen_string_literal: true

module Member
  module Workload
    module Actions
      # Genera un ticket da una workload action. Aprire un ticket è baseline (come Member::Tickets:
      # nessun tickets.edit richiesto): l'autorizzazione è vedere la action (membro del team) + vedere
      # il progetto target (VisibleScope nel service → R404). Model SEMPRE ::Workload::* fully-qualified.
      class PromotionsController < Member::BaseController
        permission_not_required "Aprire un ticket da un'azione è baseline: valgono la vista dell'azione e quella del " \
                                "progetto di destinazione."

        before_action :set_action
        before_action :require_unlinked

        def new
          load_form_options
        end

        def create
          result = ::Workload::Actions::PromoteToTicket.call(
            action: @action, reporter: Current.account, true_actor: Current.true_account, params: promotion_params
          )
          if result.ok?
            redirect_to member_ticket_path(result.value), notice: t("member.workload.actions.promoted")
          else
            load_form_options
            @draft_title = promotion_params[:title].presence || @action.title
            @draft_description = promotion_params[:description].presence || @action.description
            @errors = result.error.details || {}
            flash.now[:alert] = result.error.message
            render :new, status: :unprocessable_content
          end
        end

        private

        def set_action
          @action = visible.workload_actions.find(params[:action_id])
        end

        # Una action già linkata non rigenera: torna alla show con avviso.
        def require_unlinked
          return if @action.ticket.nil?

          redirect_to member_workload_action_path(@action), alert: t("workload.errors.already_linked")
        end

        def load_form_options
          @projects = visible.projects.order(:name)
          @draft_title ||= @action.title
          @draft_description ||= @action.description
        end

        def promotion_params
          params.permit(:project_id, :title, :description, :kind, :status_id, :priority_id)
        end
      end
    end
  end
end
