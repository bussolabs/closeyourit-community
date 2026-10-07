require "rails_helper"

RSpec.describe Coworkers::Apps do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Ops", instructions: "Help") }
  let(:run) { Coworkers::Start.call(puck: puck, kind: "chat", input: "Go").tap { |r| r.update!(status: "running") } }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(NetworkGuard).to receive_messages(resolved_public_address: "93.184.215.14", safe_url?: true, private_target?: false)
  end

  def call(name, args) = Coworkers::Tools.call(run: run, call_id: SecureRandom.uuid, name: name, args: args)

  describe "MCP tools" do
    let!(:mcp) do
      puck.connections.create!(provider: "mcp", name: "Notion", url: "https://mcp.example.com/mcp", access: "write",
                               tools: [ { "name" => "create-page", "description" => "Create", "input_schema" => { "type" => "object" }, "read_only" => false } ])
    end

    it "answers an unknown tool when no MCP connection owns the name" do
      expect(described_class.call(run, "app_zzzzzz_search", {}, nil)).to eq(error: "Unknown app tool.")
    end

    it "names the connection when the app fails while the call is prepared" do
      allow_any_instance_of(Coworkers::Connection).to receive(:write?).and_raise(Coworkers::Mcp::Error, "timeout") # rubocop:disable RSpec/AnyInstance
      expect(described_class.call(run, "#{mcp.prefix}create_page", {}, nil)).to eq(error: "Notion did not answer (timeout).")
    end

    it "reports the failure without a connection name when none was found yet" do
      allow(described_class).to receive(:reachable?).and_raise(Coworkers::Mcp::Error, "timeout")
      expect(described_class.call(run, "#{mcp.prefix}create_page", {}, nil)).to eq(error: " did not answer (timeout).")
    end
  end

  describe "GitHub tools" do
    let(:client) { instance_double(Github::Client) }

    before do
      puck.connections.create!(provider: "github", name: "GitHub")
      allow(Github::Client).to receive(:new).and_return(client)
    end

    it "says when the project has no linked repository" do
      project
      expect(call("github_issues", { "project" => "SHOP" })).to eq(error: "No GitHub repository is linked to SHOP.")
    end

    it "lists open issues without the pull requests" do
      repository = create(:github_repository, project: project)
      allow(client).to receive(:issues).and_return([ { "number" => 1, "title" => "Bug", "html_url" => "u1", "body" => "x" },
                                                     { "number" => 2, "title" => "PR", "html_url" => "u2", "pull_request" => {} } ])
      expect(call("github_issues", { "project" => "SHOP" }))
        .to eq([ { repository: repository.full_name, data: [ { "number" => 1, "title" => "Bug", "html_url" => "u1" } ] } ])
    end

    it "reads a file of the default branch" do
      repository = create(:github_repository, project: project, default_branch: "trunk")
      allow(client).to receive(:repository_file).and_return("# Shop")
      expect(call("github_file", { "project" => "SHOP", "path" => "README.md" })).to eq([ { repository: repository.full_name, data: "# Shop" } ])
      expect(client).to have_received(:repository_file)
        .with(repository.installation.installation_id, repository.full_name, "README.md", ref: "trunk")
    end
  end
end
