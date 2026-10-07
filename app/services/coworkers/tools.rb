module Coworkers
  # The single door from a Puck runtime to CloseYourIt data: the same reads and proposals as the
  # assistant, inside the run's frozen scope, with the Puck's rules applied to every proposal
  # (CYRA-1009, CYRA-1010, CYRA-1017). Local bridge and remote worker both call it.
  class Tools
    class UnknownCall < StandardError; end

    MAX_ARGS_BYTES = 16_384

    # The Puck's own tool: a note to remember, which always waits for the owner (CYRA-1012).
    REMEMBER = { name: "remember", description: "Asks the owner to remember one short fact about how they work. " \
                                                "It is saved only after the owner accepts it.",
                 input_schema: { type: "object", properties: { note: { type: "string", maxLength: 500 } },
                                 required: [ "note" ], additionalProperties: false } }.freeze

    # Hands a piece of work to another Puck of the same person (CYRA-1024).
    HAND_OFF = { name: "hand_off", description: "Hands a piece of work to another Puck by name. It starts as a task for the same person; " \
                                                "its proposals always wait for a person. Returns at once: do not wait for it.",
                 input_schema: { type: "object", properties: { puck: { type: "string", maxLength: 80 }, request: { type: "string", maxLength: 2000 } },
                                 required: %w[puck request], additionalProperties: false } }.freeze
    # A bug goes to the existing automation, which opens the pull request; the Puck follows it (CYRA-1028).
    PROPOSE_FIX = { name: "propose_agent_fix", description: "Proposes handing a ticket to the CloseYourIt automation, which works it and " \
                                                            "opens a pull request with tests. A person always confirms.",
                    input_schema: { type: "object", properties: { code: { type: "string", maxLength: 40 }, note: { type: "string", maxLength: 500 } },
                                    required: [ "code" ], additionalProperties: false } }.freeze
    FIX_STATUS = { name: "agent_fix_status", description: "Says how the automation is doing on a ticket: phase and pull request links.",
                   input_schema: { type: "object", properties: { code: { type: "string", maxLength: 40 } },
                                   required: [ "code" ], additionalProperties: false } }.freeze
    OWN = [ REMEMBER, HAND_OFF, PROPOSE_FIX, FIX_STATUS ].freeze
    # The Puck's model lost the thread on long lists: 20 error rows (about 2,900 characters) broke 20 replies in 20,
    # 12 (about 1,800) broke none. A list keeps its rows up to that size, so 14 short project rows all stay;
    # the real total stays too, so counts are still right.
    LIST_CHARS = 1_800
    MAX_DEPTH = 2
    MAX_HANDOFFS = 2

    def self.catalog = Assistant::Tools::Registry::TOOLS + Assistant::Tools::Registry::WRITE_TOOLS
    def self.names(puck = nil) = catalog.map(&:tool_name) + OWN.map { |tool| tool[:name] } + Devices.names + (puck ? Apps.names(puck) : [])

    # JSON Schema for the runtime: the assistant declares Gemini-style upper-case types.
    # An automatic check reads signals anyone can write (an error title, a log line): it may only read and propose
    # a new ticket or a comment. Live, an injected error title made a check propose a status change and a memory note.
    WATCH_WRITES = %w[propose_ticket propose_comment].freeze
    def self.watch_tool?(name) = Assistant::Tools::Registry::TOOLS.any? { |tool| tool.tool_name == name } ||
                                 WATCH_WRITES.include?(name) || name == FIX_STATUS[:name]

    def self.declarations(puck = nil, kind: nil)
      return declarations(puck).select { |tool| watch_tool?(tool[:name]) } if kind == "watch"

      base = catalog.map do |tool|
        declaration = tool.declaration
        { name: declaration[:name], description: declaration[:description],
          input_schema: json_schema(declaration[:parameters] || { type: "OBJECT", properties: {} }) }
      end + OWN + Devices.declarations
      puck ? base + Apps.declarations(puck) : base
    end

    def self.json_schema(node)
      case node
      when Hash then node.to_h { |key, value| [ key, key.to_s == "type" ? value.to_s.downcase : json_schema(value) ] }
      when Array then node.map { |value| json_schema(value) }
      else node
      end
    end

    def self.call(run:, call_id:, name:, args:)
      new(run: run, call_id: call_id.to_s, name: name.to_s, args: args.is_a?(Hash) ? args : {}).call
    end

    def initialize(run:, call_id:, name:, args:)
      @run = run
      @call_id = call_id
      @name = name
      @args = args.deep_stringify_keys
    end

    def call
      raise UnknownCall unless self.class.names(@run.puck).include?(@name) && @call_id.length.between?(1, 128)
      raise UnknownCall if @args.to_json.bytesize > MAX_ARGS_BYTES

      record = claim
      return record.result unless record.previously_new_record?

      result = @run.reload.active? && !@run.stop_requested? ? execute : { error: "This work was stopped." }
      record.update!(result: result)
      result
    end

    private

    # A resent call with the same arguments gets the stored answer; different arguments are refused.
    def claim
      @run.tool_calls.create!(call_id: @call_id, name: @name, args_digest: digest, result: { error: "Still running." })
    rescue ActiveRecord::RecordNotUnique
      existing = @run.tool_calls.find_by!(call_id: @call_id)
      raise UnknownCall unless existing.args_digest == digest && existing.name == @name

      existing
    end

    def digest = Digest::SHA256.hexdigest(@args.to_json)

    def shorten(result)
      lists = result.select { |_key, value| value.is_a?(Array) && value.to_json.size > LIST_CHARS }
      return result if lists.empty?

      shortened = result.merge(lists.transform_values { |rows| fitting(rows) })
      result.key?(:showing) ? shortened.merge(showing: shortened.values_at(*lists.keys).map(&:size).min) : shortened
    end

    def fitting(rows)
      size = 0
      kept = rows.take_while { |row| (size += row.to_json.size + 1) <= LIST_CHARS }
      kept.presence || rows.first(1)
    end

    def execute
      return { error: "An automatic check can only read and propose new tickets or comments." } if @run.kind == "watch" && !self.class.watch_tool?(@name)
      return remember if @name == REMEMBER[:name]
      return hand_off if @name == HAND_OFF[:name]
      return fix_status if @name == FIX_STATUS[:name]
      return apply_rules(propose_fix) if @name == PROPOSE_FIX[:name]
      return apply_rules(Apps.call(@run, @name, @args, Scope.context_for(@run))) if Apps.names(@run.puck).include?(@name)
      return Devices.call(@run, @name, @args) if Devices.names.include?(@name)

      result = Assistant::Tools::Registry.run(name: @name, args: @args, context: Scope.context_for(@run))
      result = apply_rules(shorten(result)) if result.is_a?(Hash)
      @run.publish
      result
    end

    def propose_fix
      context = Scope.context_for(@run)
      ticket = context.find_ticket(@args["code"])
      return { error: "No visible ticket with that code." } if ticket.nil?

      proposal = @run.action_proposals.create!(organization: @run.puck.organization, account: @run.requester, kind: :start_agent_work,
                                               payload: { "ticket_id" => ticket.id, "ticket_code" => ticket.code, "ticket_title" => ticket.title,
                                                          "note" => @args["note"].to_s.strip.first(500) })
      { proposal_id: proposal.id }
    end

    def fix_status
      ticket = Scope.context_for(@run).find_ticket(@args["code"])
      return { error: "No visible ticket with that code." } if ticket.nil?

      workflow = Agents::Workflow.find_by(ticket_id: ticket.id)
      pulls = Github::PullRequest.where(ticket_id: ticket.id).order(created_at: :desc).limit(5)
      { ticket: ticket.code, automation: ticket.agent_eligibility, phase: workflow&.phase,
        pull_requests: pulls.map { |pull| { number: pull.number, state: pull.state, url: pull.html_url, merged: pull.merged_at.present? } } }
    end

    def remember
      note = @args["note"].to_s.strip.first(500)
      return { error: "Empty note." } if note.blank?

      notes = @run.puck.memory_notes
      return { status: "already_known" } if notes.where(status: %w[pending active]).exists?(body: note)
      return { error: "Too many notes wait for the owner." } if notes.pending.count >= MemoryNote::MAX_PENDING

      notes.create!(run: @run, body: note, scope: @run.scope.slice("project_ids"))
      { status: "awaiting_owner" }
    end

    def hand_off
      chain = ancestor_puck_ids
      return { error: "Handed-off work cannot hand off further." } if chain.size > MAX_DEPTH
      return { error: "This run already handed off #{MAX_HANDOFFS} pieces of work." } if @run.child_runs.count >= MAX_HANDOFFS

      target = handoff_target(chain)
      return { error: "No other Puck with that name is available to this person." } if target.nil?
      return { error: "The person did not name #{target.name}: hand off only to a Puck they named." } unless named_by_person?(target)

      Start.call(puck: target, kind: "task", input: "From #{@run.puck.name}: #{@args['request'].to_s.strip.first(2000)}",
                 account: @run.requester, parent_run: @run)
      { status: "handed_off", puck: target.name }
    rescue Start::Busy
      { error: "#{target.name} is busy now." }
    rescue Start::OverBudget
      { error: "The monthly ceiling is reached." }
    end

    # The Puckies of this run and of the runs that handed it work, in one query.
    def ancestor_puck_ids
      sql = Run.sanitize_sql([ <<~SQL.squish, @run.id, MAX_DEPTH + 1 ])
        WITH RECURSIVE chain(id, puck_id, parent_run_id, depth) AS (
          SELECT id, puck_id, parent_run_id, 0 FROM coworkers_runs WHERE id = ?
          UNION ALL
          SELECT runs.id, runs.puck_id, runs.parent_run_id, chain.depth + 1
          FROM coworkers_runs runs JOIN chain ON runs.id = chain.parent_run_id WHERE chain.depth < ?)
        SELECT puck_id FROM chain ORDER BY depth
      SQL
      Run.connection.select_values(sql)
    end

    # A name read only in tool data (a ticket comment, an error title) never picks a target: in live runs an
    # injected comment made the Puck hand off work 4 times in 6 even with a rule against it in the prompt.
    def named_by_person?(target)
      context = @run.context
      words = [ @run.input, context.dig("identity", "instructions"), context["approvedMemory"], *Array(context["learnedMemory"]),
                *Array(context["history"]).map { |turn| turn["input"] } ]
      words.compact.join("\n").downcase.include?(target.name.downcase)
    end

    # Same person, same organization, never a Puck already in the chain.
    def handoff_target(chain)
      Authorization::VisibleScope.new(account: @run.requester, organization: @run.puck.organization).coworker_puckies
                                 .where.not(id: chain).find_by("LOWER(name) = ?", @args["puck"].to_s.strip.downcase)
    end

    def apply_rules(result)
      return result unless result.is_a?(Hash) && result[:proposal_id]

      proposal = @run.action_proposals.find(result[:proposal_id])
      decision = Policy.decide(proposal, @run.puck)
      # Unattended watch work and handed-off work never apply anything by themselves (CYRA-1011, CYRA-1024).
      unattended = @run.kind == "watch" || @run.parent_run_id.present?
      decision = Policy::Decision.new(decision: "ask", rule: decision.rule) if unattended && decision.decision == "allow"
      # Data leaving CloseYourIt passes the automatic check first (CYRA-1017).
      decision = Policy::Decision.new(decision: "ask", rule: decision.rule) if decision.decision == "allow" && proposal.kind_external_tool? && !Review.allow?(proposal)
      case decision.decision
      when "deny" then deny(proposal, decision.rule)
      when "allow" then allow(proposal, decision.rule)
      else
        proposal.update!(coworkers_rule: decision.rule)
        Notify.decision_needed(proposal)
        { proposal_id: proposal.id, status: "awaiting_confirmation" }
      end
    end

    def deny(proposal, rule)
      proposal.update!(status: :discarded, error_code: "R403-COWORKERS-002", coworkers_rule: rule)
      { status: "blocked_by_rule", message: "The Puck's rules do not allow this action." }
    end

    def allow(proposal, rule)
      proposal.update!(origin: "rule", coworkers_rule: rule)
      outcome = Assistant::Proposals::Confirm.call(proposal: proposal, account: @run.requester,
                                                   organization: @run.puck.organization,
                                                   allowed_project_ids: Scope.snapshot(@run).project_ids)
      return { proposal_id: proposal.id, status: "applied" } if outcome.ok?

      { proposal_id: proposal.id, status: "failed", message: outcome.error.message }
    end
  end
end
