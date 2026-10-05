# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Private ProGuard artifacts", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:token) { Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "Artifacts").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }
  let(:path) { "/cli/v1/projects/#{project.id}/artifacts/proguard_maps" }
  let(:mapping) { Rails.root.join("spec/fixtures/artifacts/r8-9.4.28-mapping.txt").read }
  let(:payload) { { release: "v1", debug_id: "3c4f2c60-06dc-4d5c-8c08-521d6d8ebaa2", mapping: mapping } }

  before do
    create(:membership, account: account, organization: organization, role: :owner)
  end

  it "fails closed without processor configuration and never reserves an unchecked artifact" do
    original = ENV.delete("RETRACE_PROCESSOR_URL")
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(project.proguard_map_artifacts.count).to eq(0)
    expect(Artifacts::Blob.where(project_id: project.id).count).to eq(0)
  ensure
    ENV["RETRACE_PROCESSOR_URL"] = original if original
  end

  [ "", ".json" ].each do |format|
    it "bounds raw upload reads before framework parameter parsing with format #{format.inspect}" do
      input = Class.new(StringIO) do
        attr_reader :reads
        def read(*args)
          (@reads ||= []) << args.first
          super
        end
      end.new("x" * (Artifacts::MAX_REQUEST + 1))
      env = Rack::MockRequest.env_for("#{path}#{format}", method: "POST", input: input, "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => headers["Authorization"], "HTTP_HOST" => "localhost")
      status, _headers, body = Rails.application.call(env)
      expect(status).to eq(413)
      expect(input.reads).to eq([ Artifacts::MAX_REQUEST + 1 ])
      body.close if body.respond_to?(:close)
    end
  end

  context "with the real isolated R8 processor" do
    before { skip "Set RETRACE_PROCESSOR_URL to the owned isolated processor" if ENV["RETRACE_PROCESSOR_URL"].blank? }

    it "validates actual compiler output, preserves bytes and handles immutable identity" do
      get path, headers: headers
      expect(response.parsed_body.fetch("data")).to eq([])
      post path, params: payload.to_json, headers: headers
      expect(response).to have_http_status(:created)
      first = response.parsed_body.fetch("data")
      artifact = project.proguard_map_artifacts.find(first.fetch("id"))
      expect(Artifacts::ProguardMaps::Read.call(artifact: artifact)).to eq(mapping)
      expect(first).to include("kind" => "proguard_map", "sha256" => Digest::SHA256.hexdigest(mapping))
      expect(response.body).not_to include("proof.Crash", "artifacts/")
      post path, params: payload.merge(debug_id: payload[:debug_id].delete("-").upcase, dist: "").to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data").fetch("id")).to eq(first.fetch("id"))
      post path, params: payload.merge(mapping: mapping.sub("int leaf(int)", "int renamed(int)")).to_json, headers: headers
      expect(response).to have_http_status(:conflict)
      post path, params: payload.merge(debug_id: SecureRandom.uuid).to_json, headers: headers
      expect(response).to have_http_status(:created)
      get path, headers: headers
      expect(response.parsed_body.fetch("data").size).to eq(2)
      expect(response.parsed_body).to have_key("meta")
      other = create(:project, organization: organization)
      get "/cli/v1/projects/#{other.id}/artifacts/proguard_maps/#{first.fetch('id')}", headers: headers
      expect(response).to have_http_status(:not_found)
      delete "#{path}/#{first.fetch('id')}", params: { confirm: true }.to_json, headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "rejects malformed and unsupported mappings before storage" do
      [ "not a mapping", mapping.sub('"version":"2.2"', '"version":"99.0"') ].each do |value|
        post path, params: payload.merge(mapping: value).to_json, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
      expect(Artifacts::Blob.where(project_id: project.id).count).to eq(0)
    end

    it "permits visible readers but denies unauthorized mutation and invisible lookups" do
      post path, params: payload.to_json, headers: headers
      id = response.parsed_body.fetch("data").fetch("id")
      viewer = create(:account)
      create(:membership, account: viewer, organization: organization, role: :member)
      create(:project_membership, account: viewer, project: project)
      bearer = Accounts::ApiTokens::Issue.call(account: viewer, organization: organization, name: "Reader").value[:secret]
      scoped = headers.merge("Authorization" => "Bearer #{bearer}")
      get "#{path}/#{id}", headers: scoped
      expect(response).to have_http_status(:ok)
      post path, params: payload.to_json, headers: scoped
      expect(response).to have_http_status(:forbidden)
      delete "#{path}/#{id}", params: { confirm: true }.to_json, headers: scoped
      expect(response).to have_http_status(:forbidden)
      invisible = create(:project, organization: organization)
      get "/cli/v1/projects/#{invisible.id}/artifacts/proguard_maps/#{id}", headers: scoped
      expect(response).to have_http_status(:not_found)
    end
  end
end
