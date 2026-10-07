require "rails_helper"

RSpec.describe "Puckies reach the team's tools" do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Ops", instructions: "Help") }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(NetworkGuard).to receive(:resolved_public_address).and_return("93.184.215.14")
    allow(NetworkGuard).to receive(:safe_url?).and_return(true)
    allow(NetworkGuard).to receive(:private_target?).and_return(false)
  end

  def start(kind = "chat") = Coworkers::Start.call(puck: puck, kind: kind, input: "Go").tap { |run| run.update!(status: "running") }
  def call(run, name, args) = Coworkers::Tools.call(run: run, call_id: SecureRandom.uuid, name: name, args: args)

  describe "connected apps (CYRA-1014)" do
    let(:mcp) do
      puck.connections.create!(provider: "mcp", name: "Notion", url: "https://mcp.example.com/mcp", token: "secret-token", access: "write",
                               tools: [ { "name" => "search", "description" => "Search pages", "input_schema" => { "type" => "object" }, "read_only" => true },
                                        { "name" => "create-page", "description" => "Create a page", "input_schema" => { "type" => "object" }, "read_only" => false } ])
    end

    it "keeps the token encrypted and offers the app's tools to the run" do
      mcp
      expect(Coworkers::Connection.connection.select_value("SELECT token FROM coworkers_connections")).not_to include("secret-token")
      names = start.context["railsTools"].map { |tool| tool["name"] }
      expect(names).to include("#{mcp.prefix}search", "#{mcp.prefix}create_page")
    end

    # The server's readOnlyHint is only a hint: it never authorizes sending the model's arguments out.
    it "turns every call into a proposal a person confirms, read-only hint included" do
      run = start
      allow(Coworkers::Mcp).to receive(:call_tool).and_return({ error: false, text: "Found 2 pages" })
      expect(call(run, "#{mcp.prefix}search", { "q" => "release" })[:status]).to eq("awaiting_confirmation")
      expect(Coworkers::Mcp).not_to have_received(:call_tool)
      result = call(run, "#{mcp.prefix}create_page", { "title" => "Notes" })
      expect(result[:status]).to eq("awaiting_confirmation")
      proposal = run.action_proposals.find_by!("payload->>'tool' = ?", "create-page")
      expect(proposal).to be_kind_external_tool
      Assistant::Proposals::Confirm.call(proposal: proposal, account: account, organization: organization)
      expect(Coworkers::Mcp).to have_received(:call_tool).with(mcp, "create-page", { "title" => "Notes" })
      expect(proposal.reload).to be_status_confirmed
    end

    it "never applies an outbound action alone when the automatic check says ask" do
      puck.rules.create!(action: "external_tool", decision: "allow")
      allow(Coworkers::Review).to receive(:allow?).and_return(false)
      allow(Coworkers::Mcp).to receive(:call_tool)
      expect(call(start, "#{mcp.prefix}create_page", { "title" => "Notes" })[:status]).to eq("awaiting_confirmation")
      expect(Coworkers::Mcp).not_to have_received(:call_tool)
    end

    it "stops using an app once the requester leaves the organization" do
      run = start
      allow(Coworkers::Mcp).to receive(:call_tool)
      Connections::Membership.where(account: account, organization: organization).delete_all
      expect(call(run, "#{mcp.prefix}search", {})).to include(error: a_string_including("no longer available"))
      expect(Coworkers::Mcp).not_to have_received(:call_tool)
    end

    it "refuses writes through a read-only connection and lets the person's rule run its reads" do
      mcp.update!(access: "read")
      run = start
      expect(call(run, "#{mcp.prefix}create_page", {})).to include(error: a_string_including("read-only"))
      puck.rules.create!(action: "external_tool", decision: "allow")
      allow(Coworkers::Review).to receive(:allow?).and_return(true)
      allow(Coworkers::Mcp).to receive(:call_tool).and_return({ error: false, text: "Found 2 pages" })
      expect(call(run, "#{mcp.prefix}search", { "q" => "release" })[:status]).to eq("applied")
      expect(Coworkers::Mcp).to have_received(:call_tool).with(mcp, "search", { "q" => "release" })
    end

    it "reads the GitHub pull requests of a visible project only" do
      puck.connections.create!(provider: "github", name: "GitHub")
      repository = create(:github_repository, project: project)
      client = instance_double(Github::Client, pull_requests: [ { "number" => 3, "title" => "Fix", "html_url" => "u", "user" => { "login" => "ann" } } ])
      allow(Github::Client).to receive(:new).and_return(client)
      result = call(start, "github_pull_requests", { "project" => "SHOP" })
      expect(result).to eq([ { repository: repository.full_name, data: [ { "number" => 3, "title" => "Fix", "html_url" => "u", "user" => "ann" } ] } ])
      expect(call(start("task"), "github_pull_requests", { "project" => "NOPE" })).to include(:error)
    end
  end

  describe "sites and the browser session (CYRA-1015, CYRA-1016)" do
    let!(:site) { puck.sites.create!(domain: "https://www.App.Example.com/login", username: "jane", password: "s3cret") }

    it "normalizes the domain, encrypts the login and lists only domains to the runtime" do
      expect(site.domain).to eq("app.example.com")
      expect(Coworkers::Site.connection.select_value("SELECT password FROM coworkers_sites")).not_to include("s3cret")
      run = start("task")
      expect(run.context["sites"]).to eq([ "app.example.com" ])
      expect(run.context.to_json).not_to include("s3cret")
    end

    it "gives the login only to the worker of an active task, for a known site" do
      run = start("task")
      expect(Coworkers::Session.call(run, "site_secret", { "domain" => "app.example.com" }))
        .to eq(values: { "{{app.example.com:username}}" => "jane", "{{app.example.com:password}}" => "s3cret" })
      expect(Coworkers::Session.call(run, "site_secret", { "domain" => "evil.example.net" })).to eq(error: "unknown_site")
      expect { Coworkers::Session.call(start, "site_secret", { "domain" => "app.example.com" }) }.to raise_error(Coworkers::Tools::UnknownCall)
    end

    it "stores the latest screen and refuses data that is not a JPEG" do
      run = start("task")
      jpeg = Base64.strict_encode64("\xFF\xD8\xFF\xE0fake".b)
      expect(Coworkers::Session.call(run, "attach", { "kind" => "screen", "data" => jpeg, "url" => "https://app.example.com/home" })).to eq(status: "attached")
      expect(run.reload.screen).to be_attached
      expect(Coworkers::Session.call(run, "attach", { "kind" => "screen", "data" => Base64.strict_encode64("<svg>") })).to eq(error: "invalid_attachment")
    end

    it "hands the queued clicks of the person to the worker and marks them replayed" do
      run = start("task")
      run.update!(control: "person", control_steps: [ { "id" => "s1", "action" => "point", "x" => 4, "y" => 5 } ])
      expect(Coworkers::Session.call(run, "control", {})).to eq(control: "person", steps: [ { "id" => "s1", "action" => "point", "x" => 4, "y" => 5 } ])
      expect(Coworkers::Session.call(run, "control", { "done" => [ "s1" ] })).to eq(control: "person", steps: [])
      expect(run.reload.control_steps.sole["done"]).to be(true)
    end
  end

  describe "the person's computer (CYRA-1029)" do
    it "fails closed without a connected computer and waits for the person's answer otherwise" do
      run = start
      expect(call(run, "computer_list_files", { "value" => "." })).to include(error: a_string_including("No computer"))
      device, = Coworkers::Device.issue(account: account, organization: organization, name: "Laptop")
      device.update!(last_seen_at: Time.current)
      stub_const("Coworkers::Devices::WAIT", 0.seconds)
      result = call(run, "computer_list_files", { "value" => "." })
      expect(result).to include(status: "waiting_for_person")
      device.calls.sole.update!(status: "done", result: { "output" => "README.md" })
      expect(call(run, "computer_result", { "call_id" => result[:call_id] })).to eq(status: "done", output: "README.md")
    end
  end
end
