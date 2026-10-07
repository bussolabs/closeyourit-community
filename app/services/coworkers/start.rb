module Coworkers
  class Start
    class Busy < StandardError; end
    class InvalidProposal < StandardError; end
    class OverBudget < StandardError; end

    def self.call(puck:, kind:, input: nil, proposal_run: nil, schedule: nil, slot_at: nil, account: nil, parent_run: nil,
                  channel: "web", channel_ref: {})
      account ||= puck.account
      superseded = []
      # A savepoint: a duplicate schedule slot must not abort the caller's transaction (CYRA-1001).
      run = Run.transaction(requires_new: true) do
        # Serialize approval and new discussion so an old tab cannot approve a revised plan.
        Run.connection.execute("SELECT pg_advisory_xact_lock(438219)")
        if proposal_run
          proposal_run = puck.runs.find(proposal_run.id)
          existing = Run.find_by(proposal_run_id: proposal_run.id)
          return existing if existing
          raise InvalidProposal unless kind == "task" && proposal_run.approvable_proposal?
          input = proposal_run.proposal_input
        end
        admit!(puck, kind)

        if kind == "chat"
          superseded = puck.runs.where(kind: "chat", proposal_superseded: false).where.not(proposed_task: {}).includes(:puck, :approved_task).to_a
          superseded.each { |previous| previous.update!(proposal_superseded: true) }
        end
        scope = Scope.capture(account: account, organization: puck.organization, puck: puck, parent: parent_run)
        puck.runs.create!(kind: kind, input: input, proposal_run: proposal_run, scope: scope, schedule: schedule, slot_at: slot_at,
                          account: account, parent_run: parent_run, channel: channel, channel_ref: channel_ref,
                          tokens_reserved: Limits.tokens(kind),
                          # Who is asking: without it "my tickets" had no owner and the Puck said none were assigned.
                          context: puck.context_for(kind, input, scope: scope).merge(person: { name: (account || puck.account).name }))
      end
      superseded.each(&:publish)
      ExecuteJob.perform_later(run.id) unless Coworkers.remote?
      run.publish if proposal_run
      run
    rescue ActiveRecord::RecordNotUnique
      # The same schedule slot started twice returns the run it already has (CYRA-1001).
      existing = schedule && Run.find_by(schedule_id: schedule.id, slot_at: slot_at)
      raise Busy unless existing

      existing
    end

    # Per-organization capacity, one run per Puck lane and the monthly ceiling (CYRA-1027).
    def self.admit!(puck, kind)
      Limits.stale(Run.active).update_all(status: "interrupted", error_code: "runtime_interrupted", ended_at: Time.current)
      organization_runs = Run.active.joins(:puck).where(coworkers_puckies: { organization_id: puck.organization_id })
      raise Busy if organization_runs.count >= Limits::ORGANIZATION_ACTIVE
      raise Busy if kind == "task" && organization_runs.where(kind: "task").count >= Limits::ORGANIZATION_TASKS
      raise Busy if puck.runs.active.exists?(kind: kind)
      raise OverBudget unless Budget.allows?(puck.organization, Limits.tokens(kind))
    end
    private_class_method :admit!
  end
end
