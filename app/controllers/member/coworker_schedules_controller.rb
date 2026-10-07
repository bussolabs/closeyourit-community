module Member
  # Tasks a Puck repeats at a fixed time; saving one authorizes the recurrence (CYRA-1001).
  class CoworkerSchedulesController < BaseController
    include CoworkerScoped
    before_action :require_coworker_manager
    permission_not_required "Own Puck: a schedule only starts work its owner could start by hand (CYRA-1001)"

    def create
      coworker_puck.schedules.create!(schedule_params.merge(created_by: Current.account))
      back_to_panel("tasks")
    rescue ActiveRecord::RecordInvalid
      back_to_panel("tasks", alert: t("member.coworkers.invalid"))
    end

    def update
      schedule = coworker_puck.schedules.find(params[:id])
      paused = ActiveModel::Type::Boolean.new.cast(params[:paused])
      schedule.update!(paused: paused, next_run_at: paused ? schedule.next_run_at : schedule.next_after(Time.current))
      back_to_panel("tasks")
    end

    def destroy
      coworker_puck.schedules.find(params[:id]).destroy!
      back_to_panel("tasks")
    end

    private

    def schedule_params
      params.require(:schedule).permit(:input, :frequency, :hour, :minute, :weekday, :time_zone)
    end
  end
end
