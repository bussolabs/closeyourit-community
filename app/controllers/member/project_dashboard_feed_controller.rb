# frozen_string_literal: true

module Member
  # The Dashboard section of a project's settings: connect the service, issue a new key, pause,
  # read now, disconnect. The key is shown once, rendered directly so it never reaches the session.
  # Flat controller so it does not shadow ::Dashboards. CYRA-1112
  class ProjectDashboardFeedController < Member::BaseController
    include Member::ProjectSettingsPage

    SECTION = "dashboard"

    before_action :set_project
    before_action :require_edit
    before_action :set_feed, only: %i[update destroy refresh]

    def create
      result = ::Dashboards::Feeds::Connect.call(project: @project, url: params[:url])
      @section = SECTION
      if result.ok?
        @dashboard_revealed = result.value[:token]
        load_settings
        render "member/project_settings/show", status: :created
      else
        @dashboard_errors = result.error.details
        @dashboard_url = params[:url]
        load_settings
        render "member/project_settings/show", status: :unprocessable_content
      end
    end

    def update
      @feed.update!(enabled: ActiveModel::Type::Boolean.new.cast(params[:enabled]))
      back_to_section(@feed.enabled? ? "resumed" : "paused")
    end

    def refresh
      ::Dashboards::FetchFeedJob.perform_later(@feed.id)
      back_to_section("refreshing")
    end

    def destroy
      @feed.destroy!
      back_to_section("disconnected")
    end

    private

    # `?section=`, not `#anchor`: a fragment in a redirect is lost by the fetch that follows it.
    def back_to_section(notice)
      redirect_to member_project_settings_path(@project, section: SECTION), notice: t("member.dashboards.settings.#{notice}")
    end

    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def set_feed
      @feed = @project.dashboard_feed or raise ActiveRecord::RecordNotFound
    end

    def require_edit
      require_permission!("projects.edit", scope: @project)
    end
  end
end
