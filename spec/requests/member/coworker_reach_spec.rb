require "rails_helper"

RSpec.describe "Member coworker apps, sites, screen, procedures and computers", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let!(:membership) { create(:membership, account: account, organization: organization, role: :owner) }
  let!(:puck) { Coworkers::Puck.create!(account: account, organization: organization, name: "Ops", instructions: "Help") }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(NetworkGuard).to receive(:safe_url?).and_return(true)
    allow(NetworkGuard).to receive(:private_target?).and_return(false)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def task(**attributes) = Coworkers::Start.call(puck: puck, kind: "task", input: "Download the report", account: account).tap { |run| run.update!(status: "running", **attributes) }

  it "connects GitHub and an MCP app, and adds a site, from the rules panel" do
    get member_coworker_path(puck, panel: "rules")
    expect(response.body).to include("coworkers-apps", "coworkers-add-github", "coworkers-site-form")
    post member_coworker_connections_path(puck, connection: { provider: "github", access: "read" })
    allow(Coworkers::Mcp).to receive(:list_tools).and_return([ { "name" => "search", "description" => "", "input_schema" => {}, "read_only" => true } ])
    post member_coworker_connections_path(puck), params: { connection: { provider: "mcp", name: "Notion", url: "https://mcp.example.com/mcp", token: "t", access: "write" } }
    expect(puck.connections.pluck(:provider, :name)).to contain_exactly([ "github", "GitHub" ], [ "mcp", "Notion" ])
    expect(puck.connections.find_by(provider: "mcp").tools.sole["name"]).to eq("search")
    post member_coworker_sites_path(puck), params: { site: { domain: "app.example.com", username: "jane", password: "s3cret" } }
    get member_coworker_path(puck, panel: "rules")
    expect(response.body).to include("app.example.com")
    expect(response.body).not_to include("s3cret")
  end

  it "lets the person take the screen, click and type, then give it back" do
    run = task
    run.screen.attach(io: StringIO.new("\xFF\xD8\xFFfake".b), filename: "screen.jpg", content_type: "image/jpeg")
    get member_coworker_path(puck, panel: "tasks")
    expect(response.body).to include("coworkers-take")
    post control_point_member_coworker_run_path(puck, run), params: { x: 10, y: 20 }
    expect(response).to have_http_status(:conflict)
    post control_take_member_coworker_run_path(puck, run)
    post control_point_member_coworker_run_path(puck, run), params: { x: 10, y: 20 }
    post control_type_member_coworker_run_path(puck, run), params: { value: "123456" }
    expect(run.reload.control_steps.map { |step| step.slice("action", "x", "y", "value") })
      .to eq([ { "action" => "point", "x" => 10, "y" => 20 }, { "action" => "type", "value" => "123456" } ])
    post control_give_member_coworker_run_path(puck, run)
    expect(run.reload.control).to be_nil
  end

  it "saves the person's replayed steps as a procedure without the typed text, and reuses it" do
    run = task(control_steps: [ { "id" => "a", "action" => "point", "x" => 1, "y" => 2, "done" => true },
                                { "id" => "b", "action" => "type", "value" => "123456", "done" => true } ],
               runtime_state: { "screen_url" => "https://app.example.com/reports" })
    run.update!(status: "completed")
    post member_coworker_procedures_path(puck, run_id: run.id, name: "Monthly report")
    procedure = puck.procedures.sole
    expect(procedure.steps).to include("app.example.com/reports")
    expect(procedure.steps).not_to include("123456")
    expect { post start_member_coworker_procedure_path(puck, procedure) }.to change { puck.runs.where(kind: "task").count }.by(1)
    post repeat_member_coworker_procedure_path(puck, procedure)
    expect(puck.schedules.sole.input).to include("Monthly report")
  end

  it "shows the connected computer and disconnects it in one click" do
    device, = Coworkers::Device.issue(account: account, organization: organization, name: "Laptop")
    device.update!(last_seen_at: Time.current)
    get member_coworker_path(puck, panel: "rules")
    expect(response.body).to include("Laptop", 'data-online="true"')
    delete member_coworker_device_path(puck, device)
    expect(device.reload.revoked_at).to be_present
  end
end
