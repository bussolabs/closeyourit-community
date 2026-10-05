# frozen_string_literal: true

module Member
  # Who reads the help desk (CYRA-940). A request holds a visitor's address, so seeing the project is
  # not enough: every page of the area asks for helpdesk.manage on the request's project.
  module HelpdeskAccess
    extend ActiveSupport::Concern

    private

    def helpdesk_projects
      @helpdesk_projects ||= visible.projects.order(:name).select { |project| can?("helpdesk.manage", scope: project) }
    end

    def helpdesk_requests
      visible.helpdesk_requests.where(project_id: helpdesk_projects.map(&:id))
    end

    def set_helpdesk_request
      @request_record = visible.helpdesk_requests.includes(:project).find(params[:helpdesk_request_id] || params[:id])
      require_permission!("helpdesk.manage", scope: @request_record.project)
    end
  end
end
