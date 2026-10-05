# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Error staging privacy", type: :service do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }
  let(:token_text) { "cyi_" + "a" * 40 }

  def payload(email:, event_id:)
    { "event_id" => event_id, "message" => "Failed for #{email} #{token_text}",
      "user" => { "email" => email }, "user_hash" => "client-spoof",
      "request" => { "url" => "https://alice:password@example.test/failure?token=secret", "headers" => { "Authorization" => "Bearer private-token" } },
      "exception" => { "values" => [ { "type" => "Failure", "value" => "Failed #{email}",
        "stacktrace" => { "frames" => [ { "filename" => "https://alice:password@example.test/frame", "function" => "call", "vars" => { "password" => "secret" } } ] } } ] } }
  end

  it "scrubs staging and persisted derived fields while retaining trusted distinct-user counts" do
    %w[first@example.test second@example.test].each_with_index do |email, index|
      raw = payload(email: email, event_id: "privacy-#{index}")
      staged = Errors::Ingest::Enqueue.call(project: project, payload: raw)
      expect(staged.user_hash).to eq(Digest::SHA256.hexdigest(email)[0, 16])
      expect(staged.payload.to_json).not_to include(email, token_text, "alice", "password@", "private-token")
      expect(Errors::Ingest::Normalize.call(payload: staged.payload).payload).to eq(staged.payload)
      Errors::IngestJob.perform_now(payload_id: staged.id)
    end
    expect(project.error_groups.sole.users_count).to eq(2)
    project.error_events.each do |event|
      expect([ event.payload, event.stacktrace, event.context, event.group.title, event.group.culprit ].to_json)
        .not_to include("first@example.test", "second@example.test", token_text, "alice", "private-token")
      expect(event.user_hash).not_to eq("client-spoof")
    end
  end

  it "preserves legacy staged rows, inline jobs and anonymous events" do
    staged = Errors::IngestPayload.create!(project: project, payload: { "event_id" => "legacy-staged", "message" => "Legacy", "user" => { "email" => "legacy@example.test" } })
    Errors::IngestJob.perform_now(payload_id: staged.id)
    expect(project.error_events.find_by!(event_id: "legacy-staged").user_hash).to eq(Digest::SHA256.hexdigest("legacy@example.test")[0, 16])
    Errors::IngestJob.perform_now(project_id: project.id, payload: { "event_id" => "legacy-inline", "message" => "Legacy" })
    expect(project.error_events.find_by!(event_id: "legacy-inline").user_hash).to be_nil
  end
end
