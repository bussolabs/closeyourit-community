module Coworkers
  class Start
    class Busy < StandardError; end
    class InvalidProposal < StandardError; end

    def self.call(puck:, kind:, input: nil, proposal_run: nil)
      superseded = []
      run = Run.transaction do
        # Serialize approval and new discussion so an old tab cannot approve a revised plan.
        Run.connection.execute("SELECT pg_advisory_xact_lock(438219)")
        if proposal_run
          proposal_run = puck.runs.find(proposal_run.id)
          existing = Run.find_by(proposal_run_id: proposal_run.id)
          return existing if existing
          raise InvalidProposal unless kind == "task" && proposal_run.approvable_proposal?
          input = proposal_run.proposal_input
        end
        Run.active.where("created_at < ?", 5.minutes.ago).update_all(status: "interrupted", ended_at: Time.current)
        raise Busy if Run.active.count >= 2
        raise Busy if kind == "task" && Run.active.exists?(kind: "task")
        raise Busy if puck.runs.active.exists?(kind: kind)

        if kind == "chat"
          superseded = puck.runs.where(kind: "chat", proposal_superseded: false).where.not(proposed_task: {}).includes(:puck, :approved_task).to_a
          superseded.each { |previous| previous.update!(proposal_superseded: true) }
        end
        puck.runs.create!(kind: kind, input: input, proposal_run: proposal_run, context: puck.context_for(kind, input))
      end
      superseded.each(&:publish)
      ExecuteJob.perform_later(run.id) unless Coworkers.remote?
      run.publish if proposal_run
      run
    rescue ActiveRecord::RecordNotUnique
      raise Busy
    end
  end
end
