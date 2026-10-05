require "open3"

module Coworkers
  class ExecuteJob < ApplicationJob
    queue_as :default
    self.queue_adapter = :async if Rails.env.development? && Coworkers.enabled?

    def perform(id)
      return unless Coworkers.enabled? && !Coworkers.remote?
      @run = Run.includes(:puck).find(id)
      return unless Run.where(id: id, status: "queued").update_all(status: "running", started_at: Time.current) == 1
      @run.reload
      Current.organization = @run.puck.organization # runs with this organization's AI settings (CYRA-914)
      return finish("stopped") if @run.stop_requested?
      @run.publish
      execute
    rescue StandardError
      @run.reload if @run&.persisted?
      finish("failed", "runtime_unavailable") if @run&.active?
      raise
    end

    private

    def execute
      root = Coworkers.runtime_root.realpath
      bridge = root.join("bridge.mjs")
      raise "Runtime bridge not found" unless bridge.file?
      Open3.popen2(runtime_env, "node", bridge.to_s, unsetenv_others: true, pgroup: true) do |stdin, stdout, process|
        stdin.write({ kind: @run.kind, prompt: @run.context.to_json }.to_json + "\n")
        stdin.close
        consume(stdout)
      ensure
        terminate(process) if process&.alive?
      end
    end

    # Key and address of the AI provider follow Ai::Configuration (Valhalla, then the environment) like
    # every other AI feature (CYRA-914 D11).
    def runtime_env
      config = Ai::Configuration.current
      ENV.to_h.slice("PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL", "COWORKERS_BROWSER", "COWORKERS_EGO_SPACE",
                     "COWORKERS_EGO_PAGE", "COWORKERS_REMOTE_HOST", "SSH_AUTH_SOCK", "COWORKERS_MODEL")
         .merge("AI_API_KEY" => config.api_key, "AI_BASE_URL" => config.chat_base_url).compact
    end

    def consume(stdout)
      buffer = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 200
      loop do
        @run.reload
        return finish("stopped") if @run.stop_requested?
        return finish("interrupted", "timeout") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        next unless IO.select([ stdout ], nil, nil, 0.25)
        chunk = stdout.read_nonblock(16384, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable
        buffer << chunk
        raise "Runtime output exceeded limit" if buffer.bytesize > 1_000_000
        while (line = buffer.slice!(/.*\n/))
          handle(JSON.parse(line))
        end
        return unless @run.active?
      end
      finish("failed", "runtime_interrupted") if @run.active?
    end

    def handle(event)
      case event["type"]
      when "delta"
        @run.update!(output: @run.output + event.fetch("text"))
        publish_throttled
      when "tool"
        @run.update!(tools: @run.tools + [ event.slice("id", "name").merge("success" => false) ])
      when "tool_result"
        tools = @run.tools.map { |tool| tool["id"] == event["id"] ? tool.merge("success" => event["success"]) : tool }
        @run.update!(tools: tools)
      when "proposal"
        raise "Invalid runtime proposal" unless @run.kind == "chat" && Run.valid_proposal?(event["proposal"])
        @proposal = event["proposal"]
      when "result"
        @result = event
      when "end"
        complete(event)
      end
    end

    def complete(event)
      researched = @run.kind == "chat" || @run.tools.any? { |tool| tool["success"] }
      success = event["code"] == 0 && event["reason"].nil? && @result&.fetch("success", false) && researched
      @run.output = @result["output"] if @result && @result["output"].present?
      finish(success ? "completed" : "failed", success ? nil : "runtime_failed")
    end

    def publish_throttled
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_publish && now - @last_publish < 0.25
      @run.publish
      @last_publish = now
    end

    def finish(status, error = nil)
      @run.proposed_task = @proposal if status == "completed" && @proposal
      @run.update!(status: status, error_code: error, ended_at: Time.current)
      @run.publish
    end

    def terminate(process)
      Process.kill("TERM", process.pid)
      return if process.join(3)
      Process.kill("KILL", -process.pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
