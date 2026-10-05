# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Official Sentry Go exception arrays", type: :request do
  include ActiveJob::TestHelper

  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/sentry/go-0.49.0-exception.json").read) }
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |value| project.environments << value } }
  let(:token) { Projects::Tokens::Issue.call(project: project, name: "Go SDK", host: "bugs.example.com", environment: environment).value[:token] }
  let(:headers) { { "X-Sentry-Auth" => "Sentry sentry_key=#{token.public_key}, sentry_version=7" } }

  %w[store envelope].each do |endpoint|
    it "persists the actual SDK chain through #{endpoint} and deduplicates its retry" do
      body = if endpoint == "envelope"
        [ { "event_id" => payload.fetch("event_id") }, { "type" => "event" }, payload ].map(&:to_json).join("\n") + "\n"
      else
        payload.to_json
      end
      content_type = endpoint == "envelope" ? "application/x-sentry-envelope" : "application/json"
      perform_enqueued_jobs(only: Errors::IngestJob) do
        2.times do
          post "/api/#{project.id}/#{endpoint}", params: body, headers: headers.merge("CONTENT_TYPE" => content_type)
          expect(response).to have_http_status(:ok)
        end
      end
      event = project.error_events.sole
      expect(event.event_id).to eq(payload.fetch("event_id"))
      expect(event.payload.dig("exception", "values")).to eq(payload.fetch("exception"))
      expect(event.payload.dig("sdk", "name")).to eq("sentry.go")
      expect(event.group.title).to include("outer: inner")
    end
  end

  it "normalizes both official forms identically without changing the caller payload" do
    before = payload.deep_dup
    wrapped = payload.merge("exception" => { "values" => payload.fetch("exception") })
    bare = Errors::Ingest::Normalize.call(payload: payload)
    canonical = Errors::Ingest::Normalize.call(payload: wrapped)
    expect(bare.payload).to eq(canonical.payload)
    expect(bare.title).to eq(canonical.title)
    expect(bare.stacktrace).to eq(canonical.stacktrace)
    expect(payload).to eq(before)
  end

  it "accepts zero, one and multiple valid exceptions" do
    [ [], payload.fetch("exception").first(1), payload.fetch("exception") ].each do |values|
      event = payload.merge("exception" => values)
      expect(Errors::Ingest::EventPayload.valid?(event)).to be(true)
      expect(Errors::Ingest::Normalize.call(payload: event).payload.dig("exception", "values")).to eq(values)
    end
  end

  it "rejects malformed array entries and consumed stack shapes" do
    [ [ nil ], [ 42 ], [ "invalid" ], [ { "stacktrace" => [] } ], [ { "stacktrace" => { "frames" => [ 42 ] } } ] ].each do |values|
      expect(Errors::Ingest::EventPayload.valid?(payload.merge("exception" => values))).to be(false)
    end
    expect(Errors::Ingest::EventPayload.valid?(payload.merge("exception" => "invalid"))).to be(false)
  end

  it "retains explicit handled state and scrubs before durable staging" do
    payload.fetch("exception").last.fetch("mechanism")["handled"] = false
    payload.fetch("exception").last["value"] = "password=private-go-value"
    staged = Errors::Ingest::Enqueue.call(project: project, payload: payload)
    expect(staged.payload.to_json).not_to include("private-go-value")
    expect(Errors::Ingest::Normalize.handled_in(payload)).to be(false)
    expect(Errors::Ingest::Normalize.handled_in(staged.payload)).to be(false)
  end
end
