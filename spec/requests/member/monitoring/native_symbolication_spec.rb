# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member native crash symbolication", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:group) { create(:error_group, project: project) }
  let(:event) { create(:error_event, project: project, group: group, payload: { "platform" => "native" }) }
  let(:manifest) do
    { "crash_info" => { "crashing_thread" => 0 }, "modules" => [ { "filename" => "program", "debug_id" => "a" * 32, "code_id" => "b" * 40 } ],
      "threads" => [ { "thread_id" => 42, "frames" => [ { "instruction" => "0x1234", "module_offset" => "0x234", "trust" => "context" } ] } ] }
  end
  let(:report) { project.crash_reports.create!(event_id: event.event_id, manifest: manifest) }

  before do
    create(:membership, account: account, organization: project.organization, role: :member)
    create(:project_membership, project: project, account: account)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def derived
    { "kind" => "native", "status" => "partial", "native" => { "report_id" => report.id, "manifest_sha256" => Errors::Symbolication::Native::Source.digest(manifest) },
      "frames" => [ { "thread_index" => 0, "frame_index" => 0, "module_index" => 0, "status" => "resolved",
        "locations" => [ { "function" => "<script>inner</script>", "file" => "source.c", "line" => 9 }, { "function" => "caller" } ] } ] }
  end

  def store_result(result)
    Errors::Symbolication.create!(project_id: project.id, event_id: event.id, event_created_at: event.created_at, result: result)
  end

  it "renders inline order, received addresses and exact module identities without running a processor on GET" do
    store_result(derived)
    expect(Artifacts::NativeSymbols::Processor).not_to receive(:call)
    expect(Errors::Symbolication::Record).not_to receive(:call)
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="derived-stack"]').text).to include("inner", "caller", "source.c:9", "context")
    expect(html.css('[data-test="native-location"]').map(&:text).join).to match(/inner.*caller/m)
    expect(html.at_css('[data-test="received-stack"]').text).to include("0x1234", "0x234", "context")
    expect(html.at_css('[data-test="received-stack"]').text).not_to include("caller")
    expect(html.css('[data-test="native-location"] script')).to be_empty
    expect(html.at_css('[data-test="native-build-identities"]').text).to include("a" * 32, "b" * 40)
    expect(html.at_css('[data-test="symbolication-upload-help"]')).to be_nil
    expect(report.reload.manifest).to eq(manifest)
    expect(event.reload.payload).to eq("platform" => "native")
  end

  it "shows only original addresses after artifact deletion and gates upload help by the visible project" do
    value = derived.merge("dependencies" => [ { "kind" => "native_symbol", "id" => SecureRandom.uuid } ])
    store_result(value)
    Authorization::SetAccountPermissions.call(organization: project.organization, account: account, allow_keys: [ "artifacts.manage" ])
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.css('[data-test="native-location"]')).to be_empty
    expect(html.at_css('[data-test="received-stack"]').text).to include("0x1234", "context")
    expect(html.at_css('[data-test="symbolication-upload-help"]').text).to include("native-symbols", "upload --help")
    other = create(:error_group, project: create(:project, organization: project.organization))
    get member_monitoring_error_group_path(other)
    expect(response).to have_http_status(:not_found)
    expect(Nokogiri::HTML(response.body).css('[data-test="native-frame"], [data-test="native-build-identities"]')).to be_empty
  end

  it "keeps absent and empty native reports distinct and avoids invented thread selectors" do
    event
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-test="native-thread-selector"')
    project.crash_reports.create!(event_id: event.event_id, manifest: { "threads" => [] })
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-test="native-thread-selector"')
  end

  it "shows the explicit frame budget without presenting truncated frames as a complete report" do
    manifest["threads"][0]["frames"] = Array.new(501) { { "instruction" => "0x1234" } }
    report
    get member_monitoring_error_group_path(group)
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="symbolication-reason"]').text).to include("500", "5 MiB")
    expect(html.css('[data-test="native-frame"]')).to be_empty
    expect(html.css('[data-test="native-thread-selector"]')).to be_empty
  end
end
