# frozen_string_literal: true

module Member
  # Map tab of a project (CYRA-1071): the app map kept in the repository's blueprint.json, shown read
  # only. Flat controller, like ProjectUsageController, so it does not shadow ::Projects.
  class ProjectBlueprintController < Member::BaseController
    permission_not_required "The map describes how the code of a visible project is organised: the same " \
                            "material anyone who sees the project reads in its repository."

    def show
      @project = visible.projects.find(params[:project_id])
      @stats = @project.ticket_tally
      @reading = ::Github::Repositories::Blueprint.call(project: @project)
    end
  end
end
