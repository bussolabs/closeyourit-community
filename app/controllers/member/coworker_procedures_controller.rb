module Member
  # Steps a person showed a Puck, saved and reused (CYRA-1013). Typed text is never stored: a step
  # says "type what is needed", so a code or a password shown once stays out of the procedure.
  class CoworkerProceduresController < BaseController
    include CoworkerScoped
    before_action :require_coworker_manager
    permission_not_required "Own Puck: a procedure only starts work its owner could start by hand (CYRA-1013)"

    def create
      run = coworker_puck.runs.where(kind: "task").find(params[:run_id])
      steps = run.control_steps.select { |step| step["done"] }
      return back(alert: t("member.coworkers.procedures.empty")) if steps.empty?

      coworker_puck.procedures.create!(created_by: Current.account, name: params[:name].presence || run.input.truncate(60), steps: describe(run, steps))
      back
    end

    def start
      procedure = coworker_puck.procedures.find(params[:id])
      Coworkers::Start.call(puck: coworker_puck, kind: "task", input: instruction(procedure), account: Current.account)
      back
    rescue Coworkers::Start::Busy, Coworkers::Start::OverBudget
      back(alert: t("member.coworkers.busy"))
    end

    def repeat
      procedure = coworker_puck.procedures.find(params[:id])
      coworker_puck.schedules.create!(created_by: Current.account, input: instruction(procedure), frequency: "daily", hour: 8, minute: 0,
                                      time_zone: helpers.coworker_default_time_zone)
      back
    end

    def destroy
      coworker_puck.procedures.find(params[:id]).destroy!
      back
    end

    private

    def describe(run, steps)
      start = run.runtime_state["screen_url"].presence
      lines = steps.each_with_index.map do |step, index|
        what = step["action"] == "point" ? t("member.coworkers.procedures.click", x: step["x"], y: step["y"]) : t("member.coworkers.procedures.type")
        "#{index + 1}. #{what}"
      end
      ([ (t("member.coworkers.procedures.from", url: start) if start) ] + lines).compact.join("\n")
    end

    def instruction(procedure) = "#{t('member.coworkers.procedures.follow', name: procedure.name)}\n\n#{procedure.steps}"

    def back(**options)
      redirect_to member_coworker_path(coworker_puck, panel: "tasks"), status: :see_other, **options
    end
  end
end
