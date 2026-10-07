module Coworkers
  # The person's own computer as a Puck tool (CYRA-1029). Rails only queues the request: the terminal
  # running `cyi puck connect` asks the person yes or no, enforces its folder and command allowlist and
  # sends the result back. A disconnected or revoked computer makes every call fail closed.
  module Devices
    WAIT = 20.seconds
    EXPIRES = 5.minutes
    ARGUMENT = { type: "object", properties: { value: { type: "string", maxLength: 500 } }, required: [ "value" ], additionalProperties: false }.freeze
    TOOLS = [
      { name: "computer_list_files", tool: "list_files", description: "Lists a folder on the person's connected computer. The person approves each call there." },
      { name: "computer_read_file", tool: "read_file", description: "Reads a text file on the person's connected computer. The person approves each call there." },
      { name: "computer_run_command", tool: "run_command", description: "Runs one allowed command on the person's connected computer. The person approves each call there." }
    ].freeze
    RESULT = { name: "computer_result", description: "The outcome of an earlier computer call that was still waiting for the person.",
               input_schema: { type: "object", properties: { call_id: { type: "string", maxLength: 40 } }, required: [ "call_id" ], additionalProperties: false } }.freeze

    def self.declarations = TOOLS.map { |tool| tool.slice(:name, :description).merge(input_schema: ARGUMENT) } + [ RESULT ]
    def self.names = declarations.map { |tool| tool[:name] }

    def self.call(run, name, args)
      return result(run, args["call_id"]) if name == RESULT[:name]

      device = Device.live.where(account: run.requester, organization: run.puck.organization).order(last_seen_at: :desc).first
      return { error: "No computer of this person is connected right now." } unless device&.online?

      tool = TOOLS.find { |candidate| candidate[:name] == name }.fetch(:tool)
      call = device.calls.create!(run: run, tool: tool, arguments: { "value" => args["value"].to_s.first(500) })
      wait(call)
    end

    def self.wait(call, deadline: WAIT.from_now)
      sleep 0.5 while call.reload.status.in?(%w[pending delivered]) && Time.current < deadline
      answer(call)
    end

    def self.result(run, call_id)
      call = DeviceCall.find_by(id: call_id.to_s, run: run)
      call ? answer(call) : { error: "Unknown computer call." }
    end

    def self.answer(call)
      case call.status
      when "done" then { status: "done", output: call.result["output"].to_s.first(12_000) }
      when "denied" then { status: "denied", message: "The person said no on their computer." }
      when "pending", "delivered" then { status: "waiting_for_person", call_id: call.id }
      else { status: call.status }
      end
    end
    private_class_method :wait, :result, :answer
  end
end
