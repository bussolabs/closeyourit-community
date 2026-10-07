module Coworkers
  # The tools of a Puck's connected apps (CYRA-1014): GitHub reads through the organization's GitHub App,
  # every MCP call is a proposal: the server's readOnlyHint is a hint, never an authorization to send
  # the model's arguments out. The Puck's rules (allow plus the automatic check) decide what runs alone.
  module Apps
    PROJECT = { type: "object", properties: { project: { type: "string", description: "Project key, e.g. SHOP" } },
                required: [ "project" ], additionalProperties: false }.freeze
    GITHUB = [
      { name: "github_pull_requests", description: "Open pull requests of the GitHub repositories linked to a project.", input_schema: PROJECT },
      { name: "github_issues", description: "Open issues of the GitHub repositories linked to a project.", input_schema: PROJECT },
      { name: "github_file", description: "A file of the default branch of a project's GitHub repository.",
        input_schema: { type: "object", properties: { project: { type: "string" }, path: { type: "string", maxLength: 300 } },
                        required: %w[project path], additionalProperties: false } }
    ].freeze

    def self.declarations(puck)
      connections = puck.connections.to_a
      github = connections.any? { |connection| connection.provider == "github" } ? GITHUB : []
      github + connections.select { |connection| connection.provider == "mcp" }.flat_map do |connection|
        connection.tools.map do |tool|
          { name: tool_name(connection, tool["name"]), description: "[#{connection.name}] #{tool['description']}".first(600),
            input_schema: tool["input_schema"] }
        end
      end
    end

    def self.tool_name(connection, name) = (connection.prefix + name.to_s.downcase.gsub(/[^a-z_]/, "_")).first(64)
    def self.names(puck) = declarations(puck).map { |tool| tool[:name] }

    # The requester still sees the Puck, and a team Puck's project is still in the run's scope.
    def self.reachable?(run)
      return false unless Connections::Membership.exists?(account_id: run.requester.id, organization_id: run.puck.organization_id)

      visible = Authorization::VisibleScope.new(account: run.requester, organization: run.puck.organization).coworker_puckies.exists?(id: run.puck_id)
      visible && (!run.puck.team? || Scope.snapshot(run).project_ids.include?(run.puck.project_id))
    end

    def self.call(run, name, args, context)
      return { error: "This Puck is no longer available to this person." } unless reachable?(run)
      return github(run, name, args, context) if GITHUB.any? { |tool| tool[:name] == name }

      connection = run.puck.connections.find { |candidate| candidate.provider == "mcp" && name.start_with?(candidate.prefix) }
      tool = connection&.tools&.find { |candidate| tool_name(connection, candidate["name"]) == name }
      return { error: "Unknown app tool." } if tool.nil?
      return { error: "#{connection.name} is connected read-only." } unless tool["read_only"] || connection.write?

      proposal = run.action_proposals.create!(organization: run.puck.organization, account: run.requester, kind: :external_tool,
                                              payload: { "connection_id" => connection.id, "tool" => tool["name"], "arguments" => args,
                                                         "title" => "#{connection.name}: #{tool['name']}" })
      { proposal_id: proposal.id }
    rescue Mcp::Error => e
      { error: "#{connection&.name} did not answer (#{e.message})." }
    end

    def self.github(run, name, args, context)
      project = context.find_project(args["project"])
      return { error: "No visible project with that key." } if project.nil?

      repositories = Github::Repository.where(project_id: project.id).includes(:installation).limit(3)
      return { error: "No GitHub repository is linked to #{project.key}." } if repositories.empty?

      client = Github::Client.new
      repositories.map { |repository| { repository: repository.full_name, data: github_read(client, repository, name, args) } }
    rescue Github::Client::Error => e
      { error: "GitHub did not answer (#{e.code})." }
    end

    def self.github_read(client, repository, name, args)
      installation = repository.installation.installation_id
      case name
      when "github_pull_requests"
        Array(client.pull_requests(installation, repository.full_name)).map { |pull| pull.slice("number", "title", "html_url", "user").merge("user" => pull.dig("user", "login")) }
      when "github_issues"
        Array(client.issues(installation, repository.full_name)).reject { |issue| issue["pull_request"] }.map { |issue| issue.slice("number", "title", "html_url") }
      else
        client.repository_file(installation, repository.full_name, args["path"].to_s, ref: repository.default_branch).to_s.first(12_000)
      end
    end
    private_class_method :github, :github_read
  end
end
