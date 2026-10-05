# frozen_string_literal: true

module Cli
  module V1
    # Milestone del progetto: lettura (baseline, chi vede il progetto può) + gestione gated
    # `projects.edit` (scope = progetto del path). CRUD banale inline sul model (come il canale Member
    # Member::ProjectMilestonesController, nessun service di dominio a monte). Anti-BOLA: set_project!
    # risolve dentro visible_projects (fuori scope → R404 prima del gate); milestone dentro @project.
    class MilestonesController < Cli::V1::BaseController
      before_action :set_project!
      before_action :set_milestone, only: %i[show update destroy]

      def index
        records, meta = paginate(@project.milestones.ordered)
        render_ok(MilestoneSerializer.new(records), meta: meta)
      end

      def show
        render_ok(MilestoneSerializer.new(@milestone))
      end

      def create
        return unless require_permission!("projects.edit", scope: @project)

        milestone = @project.milestones.new(milestone_params)
        milestone.created_by = Current.account
        if milestone.save
          render_created(MilestoneSerializer.new(milestone))
        else
          render_milestone_error(milestone)
        end
      end

      def update
        return unless require_permission!("projects.edit", scope: @project)

        if @milestone.update(milestone_params)
          render_ok(MilestoneSerializer.new(@milestone))
        else
          render_milestone_error(@milestone)
        end
      end

      def destroy
        return unless require_permission!("projects.edit", scope: @project)

        @milestone.destroy
        render_no_content
      end

      private

      # Anti-BOLA: la milestone si risolve DENTRO @project (già ristretto a visible_projects);
      # una milestone di un altro progetto/org → RecordNotFound → R404 (mai 403, mai leak cross-tenant).
      def set_milestone
        @milestone = @project.milestones.find(params[:id])
      end

      def milestone_params
        params.permit(:code, :label, :color, :due_on, :active)
      end

      def render_milestone_error(milestone)
        render_error("R422-MILESTONE-001", milestone.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: milestone.errors.to_hash)
      end
    end
  end
end
