# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Private native symbol artifacts", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:token) { Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "Native artifacts").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }
  let(:path) { "/cli/v1/projects/#{project.id}/artifacts/native_symbols" }

  before { create(:membership, account: account, organization: organization, role: :owner) }

  [ "", ".json" ].each do |format|
    it "bounds the complete upload before parameter parsing for format #{format.inspect}" do
      maximum = Artifacts::NativeSymbols::Processor::MAX_REQUEST
      input = Class.new(StringIO) do
        attr_reader :reads
        def read(*args)
          (@reads ||= []) << args.first
          super
        end
      end.new("x" * (maximum + 1))
      env = Rack::MockRequest.env_for("#{path}#{format}", method: "POST", input: input, "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => headers["Authorization"], "HTTP_HOST" => "localhost")
      status, _headers, body = Rails.application.call(env)
      expect(status).to eq(413)
      expect(input.reads).to eq([ maximum + 1 ])
      body.close if body.respond_to?(:close)
    end
  end

  it "stores only a processor-validated real binary and keeps metadata private and immutable" do
    payload = native_fixture.fetch("symbols").slice("format", "architecture", "debug_id", "code_id").merge("object_base64" => Base64.strict_encode64(native_bytes))
    get path, headers: headers
    expect(response.parsed_body.fetch("data")).to eq([])
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:created)
    item = response.parsed_body.fetch("data")
    expect(item).to include("kind" => "native_symbol", "byte_size" => native_bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(native_bytes))
    expect(response.body).not_to include("object_base64", "artifacts/")
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").fetch("id")).to eq(item.fetch("id"))
    artifact = project.native_symbol_artifacts.find(item.fetch("id"))
    expect(Artifacts::NativeSymbols::Read.call(artifact: artifact)).to eq(native_bytes)
    other = create(:project, organization: organization)
    get "/cli/v1/projects/#{other.id}/artifacts/native_symbols/#{artifact.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    delete "#{path}/#{artifact.id}", params: { confirm: true }.to_json, headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "allows a visible-project reader but requires artifacts.manage for mutations" do
    organization.memberships.find_by!(account: account).update!(role: :member)
    create(:project_membership, project: project, account: account)
    get path, headers: headers
    expect(response).to have_http_status(:ok)
    post path, params: {}.to_json, headers: headers
    expect(response).to have_http_status(:forbidden)
    delete "#{path}/#{SecureRandom.uuid}", params: { confirm: true }.to_json, headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "accepts a real padded ELF at twenty MiB and rejects one extra byte before storage" do
    binary = native_bytes.ljust(20.megabytes, "\0")
    payload = native_fixture.fetch("symbols").slice("format", "architecture", "debug_id", "code_id")
    post path, params: payload.merge("object_base64" => Base64.strict_encode64(binary)).to_json, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("data")).to include("byte_size" => 20.megabytes, "sha256" => Digest::SHA256.hexdigest(binary))
    post path, params: payload.merge("object_base64" => Base64.strict_encode64(binary + "\0")).to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(project.native_symbol_artifacts.count).to eq(1)
    expect(Artifacts::Blob.where(project_id: project.id).sum(:byte_size)).to eq(20.megabytes)
  end
end
