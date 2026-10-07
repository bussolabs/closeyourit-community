require "rails_helper"

RSpec.describe "Cli::V1::Coworkers::Devices", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:puck) { Coworkers::Puck.create!(account: account, organization: organization, name: "Ops", instructions: "Help") }

  before do
    create(:membership, account: account, organization: organization, role: :owner)
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
  end

  it "registers the computer, hands over one request and stores the person's answer" do
    post "/cli/v1/coworkers/devices", params: { name: "Laptop" }, headers: headers, as: :json
    id, token = response.parsed_body["data"].values_at("id", "token")
    run = Coworkers::Start.call(puck: puck, kind: "chat", input: "x")
    call = Coworkers::DeviceCall.create!(device_id: id, run: run, tool: "read_file", arguments: { "value" => "README.md" })

    post "/cli/v1/coworkers/devices/#{id}/poll", params: { device_token: token }, headers: headers, as: :json
    expect(response.parsed_body["data"]).to include("id" => call.id, "tool" => "read_file", "value" => "README.md", "puck" => "Ops")
    post "/cli/v1/coworkers/devices/#{id}/poll", params: { device_token: token }, headers: headers, as: :json
    expect(response.parsed_body["data"]).to be_nil
    post "/cli/v1/coworkers/devices/#{id}/calls/#{call.id}", params: { device_token: token, allowed: true, output: "# Shop" }, headers: headers, as: :json
    expect(call.reload).to have_attributes(status: "done", result: { "output" => "# Shop" })
  end

  it "refuses a wrong device token and fails closed after a disconnect" do
    post "/cli/v1/coworkers/devices", params: { name: "Laptop" }, headers: headers, as: :json
    id, token = response.parsed_body["data"].values_at("id", "token")
    post "/cli/v1/coworkers/devices/#{id}/poll", params: { device_token: "cyi_d_wrong" }, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    delete "/cli/v1/coworkers/devices/#{id}", params: { device_token: token }, headers: headers, as: :json
    post "/cli/v1/coworkers/devices/#{id}/poll", params: { device_token: token }, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
