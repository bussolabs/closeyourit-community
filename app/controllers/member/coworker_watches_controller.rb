module Member
  # Turns the unattended check of a Puck on or off and sets how often it runs (CYRA-1011).
  class CoworkerWatchesController < BaseController
    include CoworkerScoped
    before_action :require_coworker_manager
    permission_not_required "Own Puck: watch runs read only what the owner sees, and never apply changes (CYRA-1011)"

    def update
      every = params[:every].presence&.to_i
      return back_to_panel("rules", alert: t("member.coworkers.invalid")) unless every.nil? || Coworkers::Puck::WATCH_INTERVALS.include?(every)

      # update_columns: changing the check must not invalidate a memory edit open in another tab.
      coworker_puck.update_columns(watch_every_minutes: every, watch_next_at: every && Time.current)
      back_to_panel("rules")
    end
  end
end
