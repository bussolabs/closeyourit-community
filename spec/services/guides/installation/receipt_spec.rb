# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guides::Installation::Receipt do
  let(:project) { create(:project) }
  let(:at) { Time.current.change(usec: 123456) }
  let(:event_id) { "a" * 32 }
  let(:parameters) { { event_id: event_id, environment: "test", release: "build1" } }
  let(:observation) { Guides::Installation::Catalog.call.find { |row| row.dig("tuple", "integration") == "ruby-native" } }

  def receipt(params = parameters, selected = observation)
    described_class.call(project: project, observation: selected, parameters: params, at: at)
  end

  it "matches actual server receipt time and exact project, environment and release" do
    event = create(:error_event, group: create(:error_group, project: project), project: project, event_id: event_id, environment: "test", release: "build1", created_at: at - 2.seconds, occurred_at: at - 10.days)
    expect(receipt).to include(state: "received", received_at: event.created_at.utc.iso8601(6), trace_id: nil)
    expect(receipt(parameters.merge(release: "other"))).to include(state: "pending")
    expect(receipt(parameters.merge(environment: "other"))).to include(state: "pending")
    expect(receipt(parameters.merge(event_id: "b" * 32))).to include(state: "pending")
    expect(receipt(parameters.merge(from: (at - 1.second).utc.iso8601(9), to: at.utc.iso8601(9)))).to include(state: "pending")
  end

  it "requires explicit valid UTC bounds and nonzero exact identifiers" do
    invalid = [ { event_id: "0" * 32 }, { event_id: "A" * 32 }, { from: (at - 1.hour).iso8601 },
      { from: "2026-02-31T00:00:00Z", to: at.utc.iso8601 },
      { from: (at - 25.hours).utc.iso8601, to: at.utc.iso8601 },
      { from: at.utc.iso8601, to: (at + 1.second).utc.iso8601 } ]
    invalid.each { |values| expect { receipt(parameters.merge(values)) }.to raise_error(Guides::Installation::Invalid) }
  end

  it "does not confuse an error correlation with a persisted trace span" do
    selected = Guides::Installation::Catalog.call.find { |row| row.dig("tuple", "integration") == "php-laravel-otlp" }
    create(:error_event, group: create(:error_group, project: project), project: project, event_id: event_id, trace_id: "b" * 32, environment: "test", release: "build1", created_at: at)
    expect(receipt(parameters.merge(trace_id: "b" * 32, span_id: "c" * 16), selected)).to include(state: "pending", signal: "traces", event_id: nil)
  end
  def persist_span(owner, trace_id:, span_id:, environment:, release:)
    attributes = [ { key: "deployment.environment.name", value: { stringValue: environment } },
      { key: "service.version", value: { stringValue: release } } ]
    payload = { resourceSpans: [ { resource: { attributes: attributes }, scopeSpans: [ { spans: [ { traceId: trace_id, spanId: span_id,
      name: "installation.request", startTimeUnixNano: "1780000000123456789", endTimeUnixNano: "1780000000123456799" } ] } ] } ] }
    expect(Traces::Ingest::Record.call(project: owner, payload: payload.deep_stringify_keys).rejected).to eq(0)
    owner.trace_spans.find_by!(trace_id: trace_id, span_id: span_id)
  end

  it "requires typed environment and release on the same retained span and excludes other tenants" do
    selected = Guides::Installation::Catalog.call.find { |row| row.dig("tuple", "integration") == "php-laravel-otlp" }
    values = parameters.merge(trace_id: "b" * 32, span_id: "c" * 16)
    travel_to at do
      wrong = persist_span(project, trace_id: "b" * 32, span_id: "c" * 16, environment: "test", release: "other")
      persist_span(project, trace_id: "b" * 32, span_id: "d" * 16, environment: "other", release: "build1")
      other = create(:project)
      persist_span(other, trace_id: "b" * 32, span_id: "c" * 16, environment: "test", release: "build1")
      expect(receipt(values, selected)).to include(state: "pending")
      right = persist_span(project, trace_id: "e" * 32, span_id: "f" * 16, environment: "test", release: "build1")
      values = values.merge(trace_id: right.trace_id, span_id: right.span_id)
      expect(receipt(values, selected)).to include(state: "received", received_at: right.first_received_at.utc.iso8601(6))
      right.update_columns(first_received_at: at - 16.minutes)
      expect(receipt(values, selected)).to include(state: "pending")
      expect(wrong.reload.resource.dig("attributes", 1, "value", "stringValue")).to eq("other")
    end
  end

  it "restores the statement timeout and reports query cancellation as unavailable" do
    connection = ApplicationRecord.connection
    before_timeout = connection.select_value("SHOW statement_timeout")
    receipt
    expect(connection.select_value("SHOW statement_timeout")).to eq(before_timeout)
    instance = described_class.new(project: project, observation: observation, parameters: parameters, at: at)
    allow(instance).to receive(:error_receipt) { connection.execute("SELECT pg_sleep(0.4)") }
    expect { instance.call }.to raise_error(Guides::Installation::Unavailable, /timed out/)
    expect(connection.select_value("SHOW statement_timeout")).to eq(before_timeout)
  end

  [ [ Errors::Event, "ruby-native" ], [ Traces::Span, "php-laravel-otlp" ] ].each do |model, integration|
    it "prepares cold #{model.name} column types before applying the receipt lookup timeout" do
      project
      selected = Guides::Installation::Catalog.call.find { |row| row.dig("tuple", "integration") == integration }
      connection = ApplicationRecord.connection
      previous = connection.select_value("SHOW statement_timeout")
      introspections = 0
      model.reset_column_information
      allow(connection).to receive(:columns).and_wrap_original do |original, table, *arguments|
        if table == model.table_name
          introspections += 1
          connection.execute("SELECT pg_sleep(0.3)")
        end
        original.call(table, *arguments)
      end

      expect(receipt(parameters.merge(trace_id: "b" * 32, span_id: "c" * 16), selected)).to include(state: "pending")
      expect(introspections).to eq(1)
      expect(connection.select_value("SHOW statement_timeout")).to eq(previous)
    ensure
      model.reset_column_information
    end
  end
end
