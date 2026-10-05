# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Development laboratory boundaries" do
  let(:organization) { create(:organization, slug: "demo") }
  let(:project) { create(:project, organization:) }
  let(:account) { create(:account) }
  let(:monitor) { create(:uptime_monitor, project:, url: "http://127.0.0.1:31311/up", failure_threshold: 1) }

  it "records an actual uptime down/up transition only in development" do
    allow(Rails.env).to receive(:development?).and_return(true)
    monitor
    allow(Rails.env).to receive(:development?).and_return(false)
    stub_request(:get, monitor.url).to_return(status: 503).then.to_return(status: 200)
    expect(Uptime::Ping.call(monitor:).up).to be(false)
    expect(Uptime::Ping.call(monitor:).error).to eq("blocked_address")
    allow(Rails.env).to receive(:development?).and_return(true)
    Uptime::RecordCheck.call(monitor:, result: Uptime::Ping.call(monitor:))
    expect(monitor.reload.current_status).to eq("down")
    expect(monitor.incidents.open.count).to eq(1)
    Uptime::RecordCheck.call(monitor:, result: Uptime::Ping.call(monitor:))
    expect(monitor.reload.current_status).to eq("up")
    expect(monitor.incidents.open.count).to eq(0)
  end

  it "intercepts external notifications while preserving in-app delivery" do
    allow(Rails.env).to receive(:development?).and_return(true)
    payload = Notifications::Payload.new(organization:, project:, account:, subject: project,
      event_type: "error_new", title: "Lab fault", body: "Local scenario", url: "/lab", dedup_key: "lab:1")
    expect(Telegram::Send).not_to receive(:call)
    expect(Notifications::Deliver.email(payload:).value).to be_status_skipped
    expect(Notifications::Deliver.telegram(payload: payload.with(dedup_key: "lab:2")).value).to be_status_skipped
    expect(Notifications::Deliver.in_app(payload: payload.with(dedup_key: "lab:3")).value).to be_status_sent
  end

  it "does not attempt a webhook for the demo organization in development" do
    allow(Rails.env).to receive(:development?).and_return(true)
    channel = build(:alerting_channel, organization:)
    result = Notifications::Deliver.webhook(channel:, event_type: "server_down", subject: project, content: nil)
    expect(result.value).to eq(:lab_intercepted)
  end

  [ nil, [], [ "worker.service" ], [ "web.service", "worker.service" ], { "quantile" => 0.95 } ].each_with_index do |details, index|
    it "preserves notification details shape #{index} when intercepting external delivery" do
      allow(Rails.env).to receive(:development?).and_return(true)
      payload = Notifications::Payload.new(organization:, project:, account:, subject: project,
        event_type: "error_new", title: "Lab fault", body: "Local scenario", url: "/lab",
        details:, dedup_key: "lab:details:#{index}", mailer: ->(_notification) { raise "External delivery must remain blocked" })
      expect(Telegram::Send).not_to receive(:call)
      [ :email, :telegram ].each do |channel|
        result = Notifications::Deliver.public_send(channel, payload: payload.with(dedup_key: "lab:#{index}:#{channel}"))
        expect(result).to be_ok
        expect(result.value.reload).to be_status_skipped
        expect(result.value.details).to eq(details)
      end
    end
  end
end
