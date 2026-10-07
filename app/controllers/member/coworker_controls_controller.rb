module Member
  # The person takes the task's browser, clicks or types through the Puck's screen, then gives it back
  # (CYRA-1016). Only who asked for the task or who manages the Puck.
  class CoworkerControlsController < BaseController
    include CoworkerScoped
    before_action :load_run
    permission_not_required "Own task: the person drives the browser the Puck opened for them (CYRA-1016)"

    def take
      @run.update!(control: "person")
      back
    end

    def give
      @run.update!(control: nil)
      back
    end

    # A click on the screen image, in the image's own pixels.
    def point
      queue("action" => "point", "x" => params[:x].to_i.clamp(0, 4000), "y" => params[:y].to_i.clamp(0, 4000))
    end

    def type
      queue("action" => "type", "value" => params[:value].to_s.first(500))
    end

    private

    def load_run
      @run = coworker_puck.runs.where(kind: "task").find(params[:id])
      head :not_found unless @run.active? && (@run.requester == Current.account || coworker_puck.managed_by?(Current.account))
    end

    def queue(step)
      return head :conflict unless @run.control == "person"

      @run.with_lock { @run.update!(control_steps: @run.control_steps + [ step.merge("id" => SecureRandom.uuid, "at" => Time.current.iso8601) ]) }
      back
    end

    def back
      @run.publish
      redirect_to member_coworker_path(coworker_puck, panel: "tasks", anchor: "coworker_run_#{@run.id}"), status: :see_other
    end
  end
end
