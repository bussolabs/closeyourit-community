require "rails_helper"

RSpec.describe "Member coworker office", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let!(:membership) { create(:membership, account: account, organization: organization, role: :owner) }
  let!(:busy) { Coworkers::Puck.create!(account: account, organization: organization, name: "Researcher", instructions: "Cite your sources") }
  let!(:idle) { Coworkers::Puck.create!(account: account, organization: organization, name: "Tester", instructions: "Try every path") }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def office_puckies
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-test='coworkers-office']")["data-coworker-office-puckies-value"])
  end

  it "seats working Puckies at a desk and leaves the others free to walk" do
    busy.runs.create!(kind: "chat", input: "Find the report", status: "running")
    idle.runs.create!(kind: "chat", input: "Check the login", status: "completed")

    get member_coworker_office_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("coworkers-sidebar")
    expect(office_puckies).to contain_exactly(
      { "id" => busy.id, "name" => "Researcher", "busy" => true, "mascotKey" => "coworkers:mascot:#{organization.id}:#{account.id}:#{busy.id}" },
      { "id" => idle.id, "name" => "Tester", "busy" => false, "mascotKey" => "coworkers:mascot:#{organization.id}:#{account.id}:#{idle.id}" }
    )
  end

  it "shows each Puck's last activity with a way into its chat" do
    busy.runs.create!(kind: "chat", input: "Find the report", status: "running")

    get member_coworker_office_path

    panel = Nokogiri::HTML(response.body).at_css("[data-test='coworkers-office-puck-#{busy.id}']")
    expect(panel.text).to include("Researcher", I18n.t("member.coworkers.status.running"), "Find the report")
    expect(panel.at_css("a[href='#{member_coworker_path(busy)}']")).to be_present
  end

  it "puts every control on the stage instead of a side column" do
    busy.runs.create!(kind: "chat", input: "Find the report", status: "running")

    get member_coworker_office_path

    page = Nokogiri::HTML(response.body)
    stage = page.at_css("[data-test='coworkers-office-stage']")
    expect(page.at_css("[data-test='coworkers-office-details']")).to be_nil
    expect(stage.at_css("[data-action='coworker-office#view']")).to be_nil
    expect(stage.at_css("[data-action='coworker-office#follow']")).to be_present
    expect(stage.at_css("[data-action='coworker-office#reset']")).to be_present
    expect(stage.at_css("select, [data-action='coworker-office#choose'], [data-test='coworkers-office-rooms'], [data-test='coworkers-office-discoveries']")).to be_nil
    expect(stage.at_css("[data-test='coworkers-office-puck-#{busy.id}']")).to be_present
  end

  it "carries the dialogs the sidebar buttons open" do
    get member_coworker_office_path

    dialogs = Nokogiri::HTML(response.body).css("dialog").map { |dialog| dialog["id"] }
    expect(dialogs).to include("coworker-new", "coworker-edit-#{busy.id}", "coworker-edit-#{idle.id}")
    expect(Nokogiri::HTML(response.body).at_css("[data-test='coworkers-new-wrapper']")["data-ui--dialog-open-value"]).to eq("false")
  end

  it "leaves out Puckies of another account" do
    Coworkers::Puck.create!(account: create(:account), organization: organization, name: "Private", instructions: "Private instructions")

    get member_coworker_office_path

    expect(office_puckies.map { |puck| puck["name"] }).to contain_exactly("Researcher", "Tester")
  end

  it "says so when there is no Puck yet" do
    Coworkers::Puck.delete_all

    get member_coworker_office_path

    expect(response.body).to include("coworkers-office-empty")
    expect(response.body).not_to include("data-coworker-office-puckies-value")
  end

  it "opens rooms only from saved configuration of visible Puckies" do
    busy.update!(preset: "researcher@4")
    idle.update!(watch_every_minutes: 60)
    idle.connections.create!(provider: "github", name: "Repository", access: "read")

    get member_coworker_office_path

    page = Nokogiri::HTML(response.body)
    expect(JSON.parse(page.at_css("[data-test='coworkers-office']")["data-coworker-office-rooms-value"])).to eq(%w[archive observatory workshop])
  end

  it "does not reveal another account's configured rooms or infer roles from a name" do
    hidden = Coworkers::Puck.create!(account: create(:account), organization: organization,
                                    name: "Private researcher", instructions: "Research", preset: "researcher@4", watch_every_minutes: 15)
    hidden.connections.create!(provider: "github", name: "Private app", access: "read")

    get member_coworker_office_path

    page = Nokogiri::HTML(response.body)
    expect(JSON.parse(page.at_css("[data-test='coworkers-office']")["data-coworker-office-rooms-value"])).to eq([])
  end

  it "does not exist where Coworkers is off" do
    allow(Coworkers).to receive(:enabled?).and_return(false)

    get member_coworker_office_path

    expect(response).to have_http_status(:not_found)
  end
end
