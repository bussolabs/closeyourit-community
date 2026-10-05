# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Installations::Verify do
  let(:installation) do
    { "id" => 555, "app_id" => 123, "suspended_at" => nil,
      "account" => { "id" => 42, "login" => "test-owner", "type" => "User" } }
  end
  let(:arguments) do
    { installation_id: "555", code: "test-code", redirect_uri: "https://example.com/callback",
      client_id: "test-client", client_secret: "test-secret", app_id: "123" }
  end

  before do
    stub_request(:post, "https://github.com/login/oauth/access_token")
      .with(body: { client_id: "test-client", client_secret: "test-secret", code: "test-code",
                    redirect_uri: "https://example.com/callback" })
      .to_return(status: 200, body: { access_token: "test-user-token" }.to_json)
    stub_request(:get, "https://api.github.com/user/installations?per_page=100&page=1")
      .with(headers: { "Authorization" => "Bearer test-user-token" })
      .to_return(status: 200, body: { installations: [ installation ] }.to_json)
    stub_request(:get, "https://api.github.com/user").to_return(status: 200, body: { id: 42 }.to_json)
  end

  it "verifies a personal installation owned by the authenticated GitHub user" do
    expect(described_class.call(**arguments).value).to eq(installation)
  end

  it "rejects an installation absent from the user's installations" do
    expect(described_class.call(**arguments.merge(installation_id: "999"))).to be_err
  end

  it "rejects a different App's installation" do
    expect(described_class.call(**arguments.merge(app_id: "999"))).to be_err
  end

  it "rejects a collaborator who can access an installation but does not own it" do
    stub_request(:get, "https://api.github.com/user").to_return(status: 200, body: { id: 99 }.to_json)

    expect(described_class.call(**arguments)).to be_err
  end

  it "requires an active administrator of the GitHub organization" do
    installation["account"]["type"] = "Organization"
    stub_request(:get, "https://api.github.com/user/installations?per_page=100&page=1")
      .to_return(status: 200, body: { installations: [ installation ] }.to_json)
    stub_request(:get, "https://api.github.com/user/memberships/orgs/test-owner")
      .to_return(status: 200, body: { state: "active", role: "admin", organization: { id: 42 } }.to_json)

    expect(described_class.call(**arguments)).to be_ok
  end

  it "rejects an ordinary organization member" do
    installation["account"]["type"] = "Organization"
    stub_request(:get, "https://api.github.com/user/installations?per_page=100&page=1")
      .to_return(status: 200, body: { installations: [ installation ] }.to_json)
    stub_request(:get, "https://api.github.com/user/memberships/orgs/test-owner")
      .to_return(status: 200, body: { state: "active", role: "member", organization: { id: 42 } }.to_json)

    expect(described_class.call(**arguments)).to be_err
  end

  it "fails closed when GitHub cannot verify organization membership" do
    installation["account"]["type"] = "Organization"
    stub_request(:get, "https://api.github.com/user/installations?per_page=100&page=1")
      .to_return(status: 200, body: { installations: [ installation ] }.to_json)
    stub_request(:get, "https://api.github.com/user/memberships/orgs/test-owner").to_return(status: 403)

    expect(described_class.call(**arguments)).to be_err
  end

  it "does not accept a failed OAuth exchange" do
    stub_request(:post, "https://github.com/login/oauth/access_token")
      .to_return(status: 200, body: { error: "bad_verification_code" }.to_json)

    expect(described_class.call(**arguments)).to be_err
  end

  it "rejects oversized responses" do
    stub_request(:post, "https://github.com/login/oauth/access_token")
      .to_return(status: 200, body: "x" * (described_class::MAX_RESPONSE_BYTES + 1))

    expect(described_class.call(**arguments)).to be_err
  end

  it "fails closed on timeout without persisting any authorization" do
    stub_request(:post, "https://github.com/login/oauth/access_token").to_timeout

    expect(described_class.call(**arguments)).to be_err
  end
end
