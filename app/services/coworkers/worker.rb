module Coworkers
  class Worker
    class StaleLease < StandardError; end
    class InvalidEvent < StandardError; end
    LEASE_DURATION = 45.seconds

    def self.scope
      Run.joins(:puck).where(coworkers_puckies: { organization_id: Coworkers.worker_organization_id, account_id: Connections::Membership.where(organization_id: Coworkers.worker_organization_id, account_id: Coworkers.worker_account_ids).select(:account_id) })
    end

    def self.claim
      ReapJob.perform_now
      run = Run.transaction do
        Run.connection.execute("SELECT pg_advisory_xact_lock(438219)")
        next if scope.where(status: "running").count >= 2
        candidate = scope.where(status: "queued", stop_requested: false).order(:created_at).lock.first
        next unless candidate
        deadline = (candidate.kind == "task" ? 200 : 80).seconds.from_now
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
      when "tool" then tool(run, event)
      when "tool_result" then tool_result(run, event)
      when "proposal"
        raise InvalidEvent unless run.kind == "chat" && Run.valid_proposal?(event["proposal"])
        run.runtime_state["proposal"] = event["proposal"]
      when "result"
        raise InvalidEvent unless [ true, false ].include?(event["success"]) && event["output"].is_a?(String)
        run.runtime_state["result"] = event.slice("success", "output")
      when "end" then complete(run, event)
      else raise InvalidEvent
      end
    end

    def self.tool(run, event)
      allowed = run.kind == "task" ? %w[browser_read search_public_web read_public_page] : %w[propose_task]
      name = event["name"].to_s.delete_prefix("mcp__coworkers__")
      valid = allowed.include?(name) && event["id"].is_a?(String) && event["id"].length.between?(1, 128) &&
        run.tools.size < 8 && run.tools.none? { |tool| tool["id"] == event["id"] }
      raise InvalidEvent unless valid
      run.tools += [ event.slice("id", "name").merge("success" => false) ]
    end

    def self.tool_result(run, event)
      entry = run.tools.find { |tool| tool["id"] == event["id"] }
      raise InvalidEvent unless entry && [ true, false ].include?(event["success"])
      entry["success"] = event["success"]
    end

    def self.complete(run, event)
      result = run.runtime_state["result"]
      researched = run.kind == "chat" || run.tools.any? { |tool| tool["success"] }
      success = event["code"] == 0 && event["reason"].nil? && result&.fetch("success", false) && researched
      run.output = result["output"] if result && result["output"].present?
      run.proposed_task = run.runtime_state["proposal"] if success && run.runtime_state["proposal"]
      run.assign_attributes(status: success ? "completed" : "failed", error_code: success ? nil : "runtime_failed", ended_at: Time.current)
    end
  end
end
