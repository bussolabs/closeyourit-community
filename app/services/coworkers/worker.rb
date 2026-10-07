module Coworkers
  class Worker
    class StaleLease < StandardError; end
    class InvalidEvent < StandardError; end
    LEASE_DURATION = 45.seconds

    # Selected by who the run acts for: a team Puck's run belongs to its requester, not to the Puck's creator (CYRA-1023).
    def self.scope
      actors = Connections::Membership.where(organization_id: Coworkers.worker_organization_id, account_id: Coworkers.worker_account_ids).pluck(:account_id)
      Run.joins(:puck).where(coworkers_puckies: { organization_id: Coworkers.worker_organization_id })
         .where("COALESCE(coworkers_runs.account_id, coworkers_puckies.account_id) IN (?)", actors.presence || [ nil ])
    end

    def self.claim
      ReapJob.perform_now
      run = Run.transaction do
        Run.connection.execute("SELECT pg_advisory_xact_lock(438219)")
        next if scope.where(status: "running").count >= 2
        candidate = scope.where(status: "queued", stop_requested: false).order(:created_at).lock.first
        next unless candidate
        deadline = Limits.deadline(candidate.kind).from_now
        candidate.update!(status: "running", started_at: Time.current, worker_lease_id: SecureRandom.uuid,
          lease_expires_at: LEASE_DURATION.from_now, runtime_deadline_at: deadline)
        candidate
      end
      run&.publish
      run
    end

    def self.report(id:, lease_id:, sequence:, events:)
      validate_batch!(sequence, events)
      digest = Digest::SHA256.hexdigest(events.to_json)
      run = scope.find_by(id: id)
      raise StaleLease unless run
      run.with_lock do
        raise StaleLease unless lease_id.present? && run.worker_lease_id == lease_id
        if sequence == run.worker_sequence && run.runtime_state["last_batch_digest"] == digest
          raise StaleLease if run.active? && run.lease_expires_at <= Time.current
          return { sequence: sequence, stop: !run.active? }
        end
        validate_lease!(run, sequence)
        if run.stop_requested?
          run.update!(status: "stopped", ended_at: Time.current)
        else
          events.each { |event| apply(run, event) }
        end
        run.runtime_state["last_batch_digest"] = digest
        run.update!(worker_sequence: sequence, lease_expires_at: [ LEASE_DURATION.from_now, run.runtime_deadline_at ].min)
      end
      run.publish if events.any? || !run.active?
      { sequence: sequence, stop: !run.active? }
    end

    # A remote tool call is answered only while the lease that asked for it is still valid.
    def self.call_tool(id:, lease_id:, call_id:, name:, input:)
      run = scope.find_by(id: id)
      valid = run && lease_id.present? && run.worker_lease_id == lease_id && run.status == "running" &&
        !run.stop_requested? && run.lease_expires_at > Time.current && run.runtime_deadline_at > Time.current
      raise StaleLease unless valid

      Tools.call(run: run, call_id: call_id, name: name, args: input)
    rescue Tools::UnknownCall
      raise InvalidEvent
    end

    # Browser session calls of a remote task: same lease rules as a tool call (CYRA-1015).
    def self.session(id:, lease_id:, op:, args:)
      run = scope.find_by(id: id)
      valid = run && lease_id.present? && run.worker_lease_id == lease_id && run.status == "running" &&
        !run.stop_requested? && run.lease_expires_at > Time.current && run.runtime_deadline_at > Time.current
      raise StaleLease unless valid

      Session.call(run, op.to_s, args)
    rescue Tools::UnknownCall
      raise InvalidEvent
    end

    def self.validate_batch!(sequence, events)
      raise InvalidEvent unless sequence.is_a?(Integer) && sequence.positive? && events.is_a?(Array) && events.size <= 100
    end

    def self.validate_lease!(run, sequence)
      valid = run.status == "running" && run.lease_expires_at > Time.current &&
        run.runtime_deadline_at > Time.current && sequence == run.worker_sequence + 1
      raise StaleLease unless valid
    end

    def self.apply(run, event)
      raise InvalidEvent unless run.active? && event.is_a?(Hash)
      case event["type"]
      when "delta"
        raise InvalidEvent unless event["text"].is_a?(String)
        run.output += event["text"]
      # The runtime dropped the text it streamed (a made-up or garbled turn): the bubble starts again.
      when "reset" then run.output = ""
      when "tool" then tool(run, event)
      when "tool_result" then tool_result(run, event)
      when "proposal" then proposal(run, event)
      when "result" then result(run, event)
      when "usage" then usage(run, event)
      when "end" then complete(run, event)
      else raise InvalidEvent
      end
    end

    def self.proposal(run, event)
      raise InvalidEvent unless run.kind == "chat" && Run.valid_proposal?(event["proposal"])
      run.runtime_state["proposal"] = event["proposal"]
    end

    def self.result(run, event)
      raise InvalidEvent unless [ true, false ].include?(event["success"]) && event["output"].is_a?(String)
      run.runtime_state["result"] = event.slice("success", "output")
    end

    def self.tool(run, event)
      allowed = (run.kind == "task" ? %w[browser_read search_public_web read_public_page] : %w[propose_task]) + Tools.names(run.puck)
      name = event["name"].to_s.delete_prefix("mcp__coworkers__")
      valid = allowed.include?(name) && event["id"].is_a?(String) && event["id"].length.between?(1, 128) &&
        run.tools.size < 32 && run.tools.none? { |tool| tool["id"] == event["id"] }
      raise InvalidEvent unless valid
      run.tools += [ event.slice("id", "name").merge("success" => false) ]
    end

    # Cumulative tokens of the run so far, never more than twice what was reserved (CYRA-1027).
    def self.usage(run, event)
      raise InvalidEvent unless event["tokens"].is_a?(Integer) && event["tokens"] >= 0
      run.tokens_used = [ [ run.tokens_used, event["tokens"] ].max, run.tokens_reserved * 2 ].min
    end

    def self.tool_result(run, event)
      entry = run.tools.find { |tool| tool["id"] == event["id"] }
      raise InvalidEvent unless entry && [ true, false ].include?(event["success"])
      entry["success"] = event["success"]
    end

    def self.complete(run, event)
      result = run.runtime_state["result"]
      researched = run.kind != "task" || run.tools.any? { |tool| tool["success"] }
      success = event["code"] == 0 && event["reason"].nil? && result&.fetch("success", false) && researched
      run.output = result["output"] if result && result["output"].present?
      run.proposed_task = run.runtime_state["proposal"] if success && run.runtime_state["proposal"]
      Coworkers.log_failure(run, event) unless success
      run.assign_attributes(status: success ? "completed" : "failed", error_code: success ? nil : "runtime_failed", ended_at: Time.current)
    end
  end
end
