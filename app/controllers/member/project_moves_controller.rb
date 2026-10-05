# frozen_string_literal: true

module Member
  # Move a project or a group to another organization. Only an owner of both
  # organizations; the move runs in the background after a typed confirmation (CYRA-879).
  class ProjectMovesController < Member::BaseController
    permission_not_required "No catalog key: only the owner of both organizations moves, checked in the gates below."

    before_action :set_subject, only: %i[new preview create]
    before_action :require_owner_of_source!, only: %i[new preview create]
    before_action :set_destination, only: %i[preview create]

    def new
      @destinations = owned_destinations
    end

    def preview
      @report = plan
    end

    # A crashed move would block its subject forever: stale ones fail before planning (CYRA-879).
    def create
      Projects::Move.expire_stale!
      @report = plan
      return render(:preview, status: :unprocessable_content) if @report.blocked? || params[:confirm].to_s.strip != @subject.label

      move = Projects::Move.create!(subject: @subject.record, source_organization: Current.organization,
                                    destination_organization: @destination, requested_by: Current.account,
                                    plan: @report.to_h)
      Projects::Moves::ExecuteJob.perform_later(move.id)
      redirect_to status_path(move)
    rescue ActiveRecord::RecordNotUnique
      concurrent_move
    end

    # Found among the actor's own moves: after success the subject is no longer in this organization (CYRA-879).
    def show
      note_permission_check!
      @move = Projects::Move.where(requested_by: Current.account).find(params[:move_id])
      @subject = Projects::Moves::Subject.new(@move.subject)
    end

    private

    # A double submit loses the race on the one-active-move index: follow the move that won (CYRA-879).
    def concurrent_move
      active = Projects::Move.active.find_by(subject: @subject.record, requested_by: Current.account)
      return redirect_to(status_path(active)) if active

      @report = @report.with(blockers: [ { code: "move_in_progress", detail: @subject.label } ])
      render :preview, status: :unprocessable_content
    end

    def set_subject
      organization = Current.organization
      record = params[:group_id] ? organization.groups.find(params[:group_id]) : organization.projects.find(params[:project_id])
      @subject = Projects::Moves::Subject.new(record)
    end

    # Refused while impersonating: the most cross-tenant action in the app is done as oneself (CYRA-879).
    def require_owner_of_source!
      note_permission_check!
      allowed = current_membership&.owner? && Current.true_account == Current.account
      redirect_to root_path, alert: t("member.forbidden") unless allowed
    end

    def set_destination
      @destination = owned_destinations.find(params[:destination_id])
    end

    def owned_destinations
      owned = Connections::Membership.where(account: Current.account, role: :owner).select(:organization_id)
      Organizations::Organization.where(id: owned).where.not(id: Current.organization.id).order(:name)
    end

    def plan = Projects::Moves::Plan.call(subject: @subject, destination: @destination).value

    def status_path(move)
      record = @subject.record
      @subject.group? ? member_group_move_status_path(record, move) : member_project_move_status_path(record, move)
    end
  end
end
