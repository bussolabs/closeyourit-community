# frozen_string_literal: true

require "rails_helper"

# External delivery retries without repeating personal notifications. CYRA-1227
RSpec.describe Alerting::DeliverChannelJob, type: :job do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project:) }
  let(:channel) { create(:alerting_channel, organization: org) }
  let(:rule) { create(:alerting_rule, organization: org) }
  let(:link) { create(:alerting_rule_channel, rule:, channel:) }
  let(:token) { "original-reservation" }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:throttle_key) { "alerting:channel:#{channel.id}:error_new:#{group.id}:1" }
  let(:occurred_at) { Time.zone.at(1_700_000_000) }
  let(:args) do
    { channel_id: channel.id, rule_id: rule.id, organization_id: org.id, link_id: link.id,
      destination_digest: Digest::SHA256.hexdigest(channel.webhook_url),
      event_type: "error_new", subject_type: "Errors::Group", subject_id: group.id,
      content: { title: "Nuovo errore · Boom", body: "App::Widget#render", url: "/member/x",
                 project: { id: project.id, key: project.key, name: project.name } },
      occurred_at:, throttle_key:, reservation_token: token, window_expires_at: }
  end
  let(:window_expires_at) { 10.minutes.from_now }
  let(:url) { "https://hooks.example.test/cyi" }

  before do
    allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
    allow(Rails).to receive(:cache).and_return(cache)
    cache.write(throttle_key, token)
    args
  end

  it "uses dedicated external delivery workers" do
    expect(described_class.new.queue_name).to eq("alert_webhooks")
  end

  it "keeps retained content out of enqueue, execution and retry logs" do
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    allow(ActiveJob::Base).to receive(:logger).and_return(logger)
    stub_request(:post, url).to_timeout.then.to_return(status: 200)

    perform_enqueued_jobs { described_class.perform_later(**args) }

    expect(output.string).to include("Alerting::DeliverChannelJob")
    expect(output.string).not_to include(args.dig(:content, :title), args.dig(:content, :body))
  end

  context "with an SEO issue" do
    let(:site) { create(:seo_site, project:) }
    let(:issue) { create(:seo_issue, site:) }
    let(:rule) { create(:alerting_rule, organization: org, event_type: :seo_issue_new) }
    let(:seo_args) { args.merge(event_type: "seo_issue_new", subject_type: "Seo::Issue", subject_id: issue.id) }

    it "delivers through the site's project and retries a receiver failure" do
      request = stub_request(:post, url).to_timeout.then.to_return(status: 200)

      perform_enqueued_jobs { described_class.perform_later(**seo_args) }

      expect(request).to have_been_requested.twice
      expect(cache.read(throttle_key)).to eq(token)
    end

    it "cancels when the site is disabled during retry backoff" do
      request = stub_request(:post, url).to_timeout
      described_class.perform_now(**seo_args)
      site.update!(enabled: false)

      perform_enqueued_jobs(only: described_class)

      expect(request).to have_been_requested.once
      expect(cache.exist?(throttle_key)).to be(false)
    end

    it "cancels when the site moves to another project during retry backoff" do
      request = stub_request(:post, url).to_timeout
      described_class.perform_now(**seo_args)
      site.update_columns(project_id: create(:project, organization: org).id)

      perform_enqueued_jobs(only: described_class)

      expect(request).to have_been_requested.once
      expect(cache.exist?(throttle_key)).to be(false)
    end
  end

  [ EOFError, Net::HTTPBadResponse, Errno::EADDRNOTAVAIL, Zlib::DataError ].each do |error|
    it "retries #{error} through Active Job and finishes normally on exhaustion" do
      request = stub_request(:post, url).to_raise(error)

      expect { perform_enqueued_jobs { described_class.perform_later(**args) } }.not_to raise_error

      expect(request).to have_been_requested.times(3)
      expect(cache.exist?(throttle_key)).to be(false)
    end
  end

  it "cancels a retry when the subject moves to another project" do
    request = stub_request(:post, url).to_timeout
    described_class.perform_now(**args)
    group.update!(project: create(:project, organization: org))

    perform_enqueued_jobs(only: described_class)

    expect(request).to have_been_requested.once
    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "cancels a retry when the project moves to another organization" do
    request = stub_request(:post, url).to_timeout
    described_class.perform_now(**args)
    project.update_columns(organization_id: create(:organization).id)

    perform_enqueued_jobs(only: described_class)

    expect(request).to have_been_requested.once
    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "cancels a retry when the rule becomes restricted to another project" do
    request = stub_request(:post, url).to_timeout
    described_class.perform_now(**args)
    rule.update!(project: create(:project, organization: org))

    perform_enqueued_jobs(only: described_class)

    expect(request).to have_been_requested.once
    expect(cache.exist?(throttle_key)).to be(false)
  end

  context "with an uptime incident" do
    let(:monitor) { create(:uptime_monitor, project:) }
    let(:incident) { create(:uptime_incident, monitor:) }
    let(:rule) { create(:alerting_rule, organization: org, event_type: :uptime_down) }

    it "cancels a retry when the monitor is paused" do
      request = stub_request(:post, url).to_timeout
      described_class.perform_now(**args.merge(event_type: "uptime_down", subject_type: "Uptime::Incident", subject_id: incident.id))
      monitor.update!(active: false)

      perform_enqueued_jobs(only: described_class)

      expect(request).to have_been_requested.once
      expect(cache.exist?(throttle_key)).to be(false)
    end
  end

  context "with a Slack app destination (CYRA-1156)" do
    let(:channel) { create(:alerting_channel, :slack_app, organization: org) }
    let(:slack_args) { args.merge(destination_digest: Digest::SHA256.hexdigest(channel.target)) }

    before do
      allow(Coworkers::Slack).to receive(:post_blocks)
        .and_return({ "ok" => true, "channel" => "C0123ABCD", "ts" => "1700000000.000100" })
    end

    it "delivers the snapshot with the three buttons and remembers its rule and project" do
      described_class.perform_now(**slack_args)

      expect(Alerting::SlackMessage.sole).to have_attributes(
        rule_id: rule.id, project_id: project.id, title: args.dig(:content, :title),
        body: args.dig(:content, :body), slack_ts: "1700000000.000100"
      )
      buttons = satisfy do |blocks|
        blocks.find { _1[:type] == "actions" }[:elements].pluck(:action_id) == %w[alert_claim alert_mute alert_ticket]
      end
      expect(Coworkers::Slack).to have_received(:post_blocks).with(hash_including(blocks: buttons))
      expect(cache.read(throttle_key)).to eq(token)
    end

    it "cancels a queued delivery if its Slack destination changes" do
      frozen_args = slack_args
      channel.update!(config: { slack_channel: "C9876ABCD" })

      described_class.perform_now(**frozen_args)

      expect(Coworkers::Slack).not_to have_received(:post_blocks)
      expect(cache.exist?(throttle_key)).to be(false)
    end

    it "requeues when Slack asks to slow down and keeps the window (CYRA-1227)" do
      allow(Coworkers::Slack).to receive(:post_blocks).and_return({ "ok" => false, "error" => "ratelimited" })

      expect { described_class.perform_now(**slack_args) }.to have_enqueued_job(described_class)
      expect(cache.read(throttle_key)).to eq(token)
    end

    it "AC-7: both Slack attempts carry the same delivery id" do
      ids = []
      allow(Coworkers::Slack).to receive(:post_blocks) do |delivery_id:, **|
        ids << delivery_id
        ids.size == 1 ? { "ok" => false, "error" => "ratelimited" } : { "ok" => true, "channel" => "C0123ABCD", "ts" => "1.5" }
      end

      perform_enqueued_jobs { described_class.perform_later(**slack_args, delivery_id: "delivery-1") }

      expect(ids).to eq(%w[delivery-1 delivery-1])
      expect(Alerting::SlackMessage.count).to eq(1)
    end

    it "does not retry a Slack refusal and frees the window (CYRA-1227)" do
      allow(Coworkers::Slack).to receive(:post_blocks).and_return({ "ok" => false, "error" => "channel_not_found" })

      expect { described_class.perform_now(**slack_args) }.not_to have_enqueued_job(described_class)
      expect(Coworkers::Slack).to have_received(:post_blocks).once
      expect(cache.exist?(throttle_key)).to be(false)
    end
  end

  it "consegna il testo fissato all'evento, con progetto e ora dell'evento" do
    stub = stub_request(:post, url).to_return(status: 200)

    described_class.perform_now(**args)

    expect(stub.with { |req|
      body = JSON.parse(req.body)
      body["title"] == "Nuovo errore · Boom" && body.dig("project", "id") == project.id &&
        body.dig("subject", "id") == group.id && body["occurred_at"] == occurred_at.iso8601
    }).to have_been_requested
    expect(cache.exist?(throttle_key)).to be(true) # consegnato: la finestra resta occupata
  end

  it "AC-2: il primo invio scade → il lavoro torna in coda per un altro tentativo, finestra ancora occupata" do
    stub_request(:post, url).to_timeout

    expect { described_class.perform_now(**args) }.to have_enqueued_job(described_class).with(**args)
    expect(cache.exist?(throttle_key)).to be(true)
  end

  it "AC-1: il canale non risponde al primo invio e risponde al secondo → l'avviso arriva" do
    stub = stub_request(:post, url).to_timeout.then.to_return(status: 200)

    perform_enqueued_jobs { described_class.perform_later(**args) }

    expect(stub).to have_been_requested.twice
    expect(cache.exist?(throttle_key)).to be(true)
  end

  it "un server occupato (503) viene ritentato come un timeout" do
    stub = stub_request(:post, url).to_return(status: 503).then.to_return(status: 200)

    perform_enqueued_jobs { described_class.perform_later(**args) }

    expect(stub).to have_been_requested.twice
  end

  it "stops after three attempts and releases the window" do
    stub = stub_request(:post, url).to_timeout
    allow(Rails.logger).to receive(:warn)

    perform_enqueued_jobs { described_class.perform_later(**args) }

    expect(stub).to have_been_requested.times(3)
    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "AC-4: il canale risponde «non trovato» → un solo tentativo e la finestra libera" do
    stub = stub_request(:post, url).to_return(status: 404)

    expect { described_class.perform_now(**args) }.not_to have_enqueued_job(described_class)

    expect(stub).to have_been_requested.once
    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "uses the common increasing retry delay" do
    stub_request(:post, url).to_timeout

    freeze_time do
      described_class.perform_now(**args)

      expect(Time.zone.at(enqueued_jobs.last.fetch(:at))).to be_between(3.seconds.from_now, 4.seconds.from_now)
      retry_job = enqueued_jobs.pop
      ActiveJob::Base.execute(retry_job)
      expect(Time.zone.at(enqueued_jobs.last.fetch(:at))).to be_between(18.seconds.from_now, 21.seconds.from_now)
    end
  end

  it "canale spento mentre si ritentava → nessun invio" do
    channel.update!(enabled: false)
    stub = stub_request(:post, url).to_return(status: 200)

    described_class.perform_now(**args)

    expect(stub).not_to have_been_requested
  end

  it "problema sparito mentre si ritentava → nessun invio, nessun errore" do
    stub = stub_request(:post, url).to_return(status: 200)
    group.destroy!

    expect { described_class.perform_now(**args) }.not_to raise_error
    expect(stub).not_to have_been_requested
  end

  it "keeps event content stable and signs the current send time on each retry" do
    bodies = []
    signatures = []
    stub_request(:post, url).to_return do |request|
      bodies << request.body
      signatures << request.headers.fetch("X-Closeyourit-Signature")
      { status: bodies.size == 1 ? 503 : 200 }
    end
    project.update!(name: "Changed after enqueue")
    group.update!(title: "Changed error")

    described_class.perform_now(**args)
    travel 10.seconds do
      perform_enqueued_jobs(only: described_class)
    end

    expect(bodies.size).to eq(2)
    payloads = bodies.map { |body| JSON.parse(body) }
    expect(payloads.map { |payload| payload.except("sent_at") }.uniq.size).to eq(1)
    expect(Time.iso8601(payloads.last.fetch("sent_at"))).to be > Time.iso8601(payloads.first.fetch("sent_at"))
    bodies.zip(signatures).each do |body, signature|
      expect(signature).to eq("sha256=#{OpenSSL::HMAC.hexdigest("SHA256", channel.webhook_secret, body)}")
    end
    expect(JSON.parse(bodies.last).dig("project", "name")).to eq(args.dig(:content, :project, :name))
  end

  it "R-1: every attempt carries the same delivery id, so the receiver can drop a duplicate" do
    ids = []
    stub_request(:post, url).to_return do |request|
      ids << [ JSON.parse(request.body)["delivery_id"], request.headers["X-Closeyourit-Delivery"] ]
      { status: ids.size == 1 ? 503 : 200 }
    end

    perform_enqueued_jobs { described_class.perform_later(**args, delivery_id: "delivery-1") }

    expect(ids).to eq([ %w[delivery-1 delivery-1] ] * 2)
  end

  describe "AC-8: the window ends while the alert waits" do
    let(:window_expires_at) { 90.seconds.from_now }

    it "sends nothing on a retry that starts after the window" do
      stub = stub_request(:post, url).to_timeout
      described_class.perform_now(**args)
      expect(stub).to have_been_requested.once

      travel 91.seconds do
        expect { perform_enqueued_jobs(only: described_class) }.not_to raise_error
      end

      expect(stub).to have_been_requested.once
      expect(enqueued_jobs).to be_empty
    end

    it "sends nothing when the queue first picks it up after the window" do
      stub = stub_request(:post, url).to_return(status: 200)

      travel_to(window_expires_at + 1.second) { described_class.perform_now(**args) }

      expect(stub).not_to have_been_requested
    end

    it "still sends a moment before the window ends" do
      stub = stub_request(:post, url).to_return(status: 200)

      travel_to(window_expires_at - 1.second) { described_class.perform_now(**args) }

      expect(stub).to have_been_requested.once
    end

    it "sends nothing once a newer event owns the window" do
      stub = stub_request(:post, url).to_return(status: 200)
      cache.write(throttle_key, "successor")

      described_class.perform_now(**args)

      expect(stub).not_to have_been_requested
      expect(cache.read(throttle_key)).to eq("successor")
    end
  end

  # The approved plan (WI-3) has the frozen alert text travel with the job: this pins what that means.
  it "stores in the queue only the frozen alert text and ids, never the destination or its secret" do
    channel.update!(webhook_secret: "s3cret-value")
    job = described_class.perform_later(**args, delivery_id: "delivery-1")
    stored = job.serialize.to_json

    expect(stored).not_to include(channel.webhook_url)
    expect(stored).not_to include("s3cret-value")
    expect(job.arguments.first[:content].keys).to contain_exactly(:title, :body, :url, :project)
    expect(job.arguments.first[:content][:project].keys).to contain_exactly(:id, :key, :name)
    expect(Rails.application.config.solid_queue.clear_finished_jobs_after).to eq(1.hour)
  end

  it "retries when the resolver does not answer" do
    stub = stub_request(:post, url).to_return(status: 200)
    allow(NetworkGuard).to receive(:resolve).and_return([], [ "93.184.216.34" ])

    perform_enqueued_jobs { described_class.perform_later(**args) }

    expect(stub).to have_been_requested.once
    expect(cache.exist?(throttle_key)).to be(true)
  end

  it "refuses a rule of another type than the event" do
    stub = stub_request(:post, url).to_return(status: 200)

    described_class.perform_now(**args, event_type: "uptime_down")

    expect(stub).not_to have_been_requested
    expect(cache.exist?(throttle_key)).to be(false)
  end

  # WI-4 — the return under threshold is sent through the rule of its measurement (CYRA-1256).
  describe "return under threshold" do
    let(:host) { create(:server_host, organization: org) }
    let(:rule) { create(:alerting_rule, organization: org, event_type: :server_disk, threshold: 80) }
    let(:recovery) do
      args.merge(event_type: "server_threshold_recovered", subject_type: "Servers::Host", subject_id: host.id,
                 content: { title: "Disco rientrato · apps", body: "70%", url: "/member/servers", project: nil },
                 metric: "server_disk")
    end

    it "is delivered through the rule of its own measurement" do
      stub = stub_request(:post, url).to_return(status: 200)

      described_class.perform_now(**recovery)

      expect(stub.with { |req| JSON.parse(req.body)["event_type"] == "server_threshold_recovered" })
        .to have_been_requested
    end

    it "is refused through a rule of another measurement or without one" do
      stub = stub_request(:post, url).to_return(status: 200)

      described_class.perform_now(**recovery, metric: "server_cpu")
      described_class.perform_now(**recovery, metric: nil)
      described_class.perform_now(**recovery, metric: "error_new")

      expect(stub).not_to have_been_requested
    end
  end

  it "checks public addresses again before a retry" do
    stub = stub_request(:post, url).to_timeout
    described_class.perform_now(**args)
    allow(NetworkGuard).to receive(:resolve).and_return([ "127.0.0.1" ])

    perform_enqueued_jobs(only: described_class)

    expect(stub).to have_been_requested.once
    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "does not retry a programming error and releases its reservation" do
    stub_request(:post, url).to_raise(NoMethodError)

    expect { described_class.perform_now(**args) }.to raise_error(NoMethodError)

    expect(enqueued_jobs).to be_empty
    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "releases the window if enqueueing a retry is aborted" do
    stub_request(:post, url).to_timeout
    job = described_class.new(**args)
    allow(job).to receive(:enqueue).and_return(false)

    job.perform_now

    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "releases the window if enqueueing a retry raises" do
    stub_request(:post, url).to_timeout
    job = described_class.new(**args)
    allow(job).to receive(:enqueue).and_raise(ActiveJob::EnqueueError)

    expect { job.perform_now }.to raise_error(ActiveJob::EnqueueError)

    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "cancels the retry when its destination has changed" do
    stub = stub_request(:post, url).to_timeout
    described_class.perform_now(**args)
    channel.update!(config: { url: "https://new.example.test/hook" })

    perform_enqueued_jobs(only: described_class)

    expect(stub).to have_been_requested.once
    expect(cache.exist?(throttle_key)).to be(false)
  end

  it "does not release a newer reservation after an old delivery fails" do
    cache.write(throttle_key, "successor")
    stub_request(:post, url).to_return(status: 410)

    described_class.perform_now(**args)

    expect(cache.read(throttle_key)).to eq("successor")
  end

  it "preserves a successor acquired while the old request is in flight" do
    freeze_time do
      cache.write(throttle_key, token, expires_in: 10.seconds)
      successor = nil
      stub_request(:post, url).to_return do
        travel 11.seconds
        successor = Alerting::ChannelReservation.acquire(channel:, key: throttle_key, expires_in: 10.seconds)
        { status: 410 }
      end

      described_class.perform_now(**args)

      expect(successor).to be_present
      expect(cache.read(throttle_key)).to eq(successor)
    end
  end

  it "signs the frozen content with the current secret after rotation" do
    bodies = []
    signatures = []
    stub_request(:post, url).to_return do |request|
      bodies << request.body
      signatures << request.headers.fetch("X-Closeyourit-Signature")
      { status: bodies.size == 1 ? 503 : 200 }
    end
    described_class.perform_now(**args)
    channel.update!(webhook_secret: "rotated-secret")

    perform_enqueued_jobs(only: described_class)

    expect(bodies.size).to eq(2)
    expect(bodies.map { |body| JSON.parse(body).except("sent_at") }.uniq.size).to eq(1)
    expect(signatures.last).to eq("sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "rotated-secret", bodies.last)}")
    expect(signatures.last).not_to eq(signatures.first)
  end

  it "never redirects a queued event and allows a fresh event at the new destination" do
    old_destination = stub_request(:post, url).to_timeout
    new_destination = stub_request(:post, "https://new.example.test/hook").to_return(status: 200)
    described_class.perform_now(**args)
    channel.update!(config: { url: "https://new.example.test/hook" })

    perform_enqueued_jobs(only: described_class)

    expect(old_destination).to have_been_requested.once
    expect(new_destination).not_to have_been_requested
    successor = Alerting::ChannelReservation.acquire(channel:, key: throttle_key, expires_in: 60.seconds)
    expect(successor).to be_present

    described_class.perform_now(**args.merge(destination_digest: Digest::SHA256.hexdigest(channel.webhook_url),
                                             reservation_token: successor))

    expect(new_destination).to have_been_requested.once
    expect(cache.read(throttle_key)).to eq(successor)
  end

  it "does not release a newer reservation when retries are exhausted" do
    cache.write(throttle_key, "successor")
    stub_request(:post, url).to_timeout

    perform_enqueued_jobs { described_class.perform_later(**args) }

    expect(cache.read(throttle_key)).to eq("successor")
  end

  shared_examples "a cancelled delivery" do
    it "does not send or retry and releases the original reservation" do
      stub = stub_request(:post, url).to_return(status: 200)
      cancel_delivery

      expect { described_class.perform_now(**args) }.not_to have_enqueued_job(described_class)

      expect(stub).not_to have_been_requested
      expect(cache.exist?(throttle_key)).to be(false)
    end

    it "rechecks authorization after the first attempt and cancels the retry" do
      stub = stub_request(:post, url).to_timeout
      described_class.perform_now(**args)
      expect(cache.read(throttle_key)).to eq(token)
      cancel_delivery

      perform_enqueued_jobs(only: described_class)

      expect(stub).to have_been_requested.once
      expect(enqueued_jobs).to be_empty
      expect(cache.exist?(throttle_key)).to be(false)
    end
  end

  context "when the destination changes" do
    def cancel_delivery = channel.update!(config: { url: "https://new.example.test/hook" })
    include_examples "a cancelled delivery"
  end

  context "when the channel is removed" do
    def cancel_delivery = channel.destroy!
    include_examples "a cancelled delivery"
  end

  context "when the channel is disabled" do
    def cancel_delivery = channel.update!(enabled: false)
    include_examples "a cancelled delivery"
  end

  context "when the rule is disabled" do
    def cancel_delivery = rule.update!(enabled: false)
    include_examples "a cancelled delivery"
  end

  context "when the rule is removed" do
    def cancel_delivery = rule.destroy!
    include_examples "a cancelled delivery"
  end

  context "when the rule is muted" do
    def cancel_delivery = rule.update!(muted_until: 1.hour.from_now)
    include_examples "a cancelled delivery"
  end

  context "when the channel is unlinked then linked again" do
    def cancel_delivery
      link.destroy!
      create(:alerting_rule_channel, rule:, channel:)
    end
    include_examples "a cancelled delivery"
  end

  context "when the channel moves to another organization" do
    def cancel_delivery = channel.update_columns(organization_id: create(:organization).id)
    include_examples "a cancelled delivery"
  end

  context "when the rule moves to another organization" do
    def cancel_delivery = rule.update_columns(organization_id: create(:organization).id)
    include_examples "a cancelled delivery"
  end
end
