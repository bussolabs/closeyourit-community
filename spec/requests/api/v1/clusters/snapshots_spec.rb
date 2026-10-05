# frozen_string_literal: true

require "rails_helper"

# Server side of the cluster-snapshot/v1 contract (CYAG-22): the vendored bundle is the oracle.
RSpec.describe "Api::V1::Clusters::Snapshots", type: :request do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:issued) { Clusters::Tokens::Issue.call(organization:, name: "lab").value }
  let(:cluster) { issued[:cluster] }
  let(:headers) { { "Authorization" => "Bearer #{issued[:secret]}", "CONTENT_TYPE" => "application/json" } }
  let(:bundle) { Rails.root.join("contracts/cluster-snapshot/v1") }
  let(:complete) { bundle.join("fixtures/valid/complete.json").read }
  let(:path) { "/api/v1/clusters/snapshots" }

  it "keeps the vendored bundle pinned and intact" do
    sums = bundle.join("SHA256SUMS").read
    sums.each_line do |line|
      digest, relative = line.chomp.split("  ./", 2)
      expect(Digest::SHA256.hexdigest(bundle.join(relative).binread)).to eq(digest), relative
    end
    lock = JSON.parse(Rails.root.join("contracts/cluster-snapshot/LOCK.json").read)
    expect(lock).to include("contract" => "cluster-snapshot/v1", "sha256sums" => Digest::SHA256.hexdigest(sums))
  end

  %w[minimal complete no_metrics limits].each do |name|
    it "accepts the #{name} contract snapshot" do
      post path, params: bundle.join("fixtures/valid/#{name}.json").read, headers: headers
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "cluster_id")).to eq(cluster.id)
    end
  end

  it "records the arrival time and queues the ingest" do
    freeze_time do
      expect { post path, params: complete, headers: headers }.to have_enqueued_job(Clusters::IngestJob).once
      expect(cluster.reload.last_snapshot_at).to eq(Time.current)
    end
  end

  it "accepts a gzip body" do
    post path, params: ActiveSupport::Gzip.compress(complete), headers: headers.merge("Content-Encoding" => "gzip")
    expect(response).to have_http_status(:accepted)
  end

  it "accepts the same snapshot twice but ingests it once" do
    post path, params: complete, headers: headers
    expect { post path, params: complete, headers: headers }.not_to have_enqueued_job(Clusters::IngestJob)
    expect(response).to have_http_status(:accepted)
  end

  it "rejects an unknown token" do
    post path, params: complete, headers: headers.merge("Authorization" => "Bearer cyi_k_nope")
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-CLUSTER-001")
  end

  it "tells a revoked token apart" do
    cluster.update!(revoked_at: Time.current)
    post path, params: complete, headers: headers
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-CLUSTER-002")
  end

  it "rejects a fleet token" do
    fleet = Servers::EnrollmentTokens::Issue.call(organization:, name: "fleet").value[:secret]
    post path, params: complete, headers: headers.merge("Authorization" => "Bearer #{fleet}")
    expect(response.parsed_body.dig("error", "code")).to eq("R401-CLUSTER-001")
  end

  it "rejects a payload without snapshot_id" do
    post path, params: bundle.join("fixtures/invalid/missing_snapshot_id.json").read, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-CLUSTER-001")
  end

  it "rejects a body that is not JSON" do
    post path, params: "not json", headers: headers
    expect(response.parsed_body.dig("error", "code")).to eq("R422-CLUSTER-001")
  end

  it "stops listening to a suspended organization" do
    organization.update!(suspended_at: Time.current)
    post path, params: complete, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-ORGANIZATION-002")
  end

  it "rejects a body over 1 MiB" do
    post path, params: "x" * (Clusters::Constants::MAX_PAYLOAD_BYTES + 1), headers: headers
    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body.dig("error", "code")).to eq("R413-CLUSTER-001")
  end
end
