# frozen_string_literal: true

# Session recordings are masked by the browser SDK and queued as received (approved plan, CYRA-1210):
# for them `scrubbed_queue` is false and only the logs are checked to stay private.
RSpec.shared_examples "private ingest boundary" do |channel, job_class, recorder, record_method, scrubbed_queue = true|
  let(:privacy_scrubbed_queue) { scrubbed_queue }
  let(:privacy_email) { "private-recipient-1210@example.test" }
  let(:privacy_token) { "private-token-1210" }
  let(:privacy_marker) { "received-content-1210" }
  let(:privacy_path) { "/api/v1/projects/#{project.id}/#{channel}" }

  def capture_ingest_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = Logger::DEBUG
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  def expect_private_serialization(job)
    serialized = job.serialize.to_json
    if privacy_scrubbed_queue
      expect(serialized).not_to include(privacy_email, privacy_token)
    else
      expect(serialized).to include(privacy_email)
    end
    expect(serialized).to include(project.id)
  end

  [ false, true ].each do |batch|
    it "keeps #{batch ? 'batch' : 'single'} content out of request logs and serialized jobs" do
      body = batch ? [ privacy_payload, privacy_payload ] : privacy_payload
      output = capture_ingest_log { post privacy_path, params: body.to_json, headers: headers }

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("data", "accepted")).to eq(batch ? 2 : 1)
      expect(output).to include("Parameters:", "Enqueued")
      expect(output).not_to include(privacy_email, privacy_token, privacy_marker)
      queued = enqueued_jobs.find { |item| item[:job] == job_class }
      expect(queued).to be_present
      expect_private_serialization(job_class.deserialize(queued))
    end
  end

  it "hides rejected requests before authentication" do
    output = capture_ingest_log do
      post privacy_path, params: privacy_payload.to_json, headers: headers.except("Authorization")
    end
    expect(response).to have_http_status(:unauthorized)
    expect(output).to include("Parameters:")
    expect(output).not_to include(privacy_email, privacy_token, privacy_marker)
    expect(enqueued_jobs.none? { |item| item[:job] == job_class }).to be(true)
  end

  it "hides malformed JSON even at debug level" do
    output = capture_ingest_log do
      post privacy_path, params: "{\"private\":\"#{privacy_email}", headers: headers
    end
    expect(response).to have_http_status(:unprocessable_content)
    expect(output).not_to include(privacy_email)
    expect(enqueued_jobs.none? { |item| item[:job] == job_class }).to be(true)
  end

  it "hides oversized batches without queuing them" do
    limit = job_class.module_parent.const_get(:Constants).const_get(:MAX_BATCH)
    output = capture_ingest_log do
      post privacy_path, params: Array.new(limit + 1, privacy_payload).to_json, headers: headers
    end
    expect(response).to have_http_status(:content_too_large)
    expect(output).not_to include(privacy_email, privacy_token, privacy_marker)
    expect(enqueued_jobs.none? { |item| item[:job] == job_class }).to be(true)
  end

  it "logs successful execution without recording its arguments" do
    post privacy_path, params: privacy_payload.to_json, headers: headers
    job = job_class.deserialize(enqueued_jobs.find { |item| item[:job] == job_class })
    output = capture_ingest_log { job.perform_now }
    expect(output).to include("Performed #{job_class.name}")
    expect(output).not_to include(privacy_email, privacy_token, privacy_marker)
  end

  it "scrubs an accepted maximum-size batch and reports its reception time" do
    limit = job_class.module_parent.const_get(:Constants).const_get(:MAX_BATCH)
    body = Array.new(limit, privacy_payload).to_json
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    post privacy_path, params: body, headers: headers
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(limit)
    queued = enqueued_jobs.find { |item| item[:job] == job_class }
    expect_private_serialization(job_class.deserialize(queued))
    RSpec.configuration.reporter.message("#{channel}: #{limit} entries, #{body.bytesize} bytes, #{elapsed.round(3)} seconds")
  end

  it "keeps execution and retry logs private and reserializes only scrubbed arguments" do
    post privacy_path, params: privacy_payload.to_json, headers: headers
    queued = enqueued_jobs.find { |item| item[:job] == job_class }
    job = job_class.deserialize(queued)
    allow(recorder).to receive(record_method).and_raise(ActiveRecord::Deadlocked, "temporary storage failure")

    output = capture_ingest_log { job.perform_now }
    expect(output).to include(job_class.name, "Retrying")
    expect(output).not_to include(privacy_email, privacy_token, privacy_marker)
    retried = enqueued_jobs.select { |item| item[:job] == job_class }.last
    expect(retried["executions"]).to eq(1)
    expect_private_serialization(job_class.deserialize(retried))
  end

  it "keeps terminal failure logs private" do
    post privacy_path, params: privacy_payload.to_json, headers: headers
    job = job_class.deserialize(enqueued_jobs.find { |item| item[:job] == job_class })
    allow(recorder).to receive(record_method).and_raise(RuntimeError, "permanent storage failure")

    output = capture_ingest_log do
      expect { job.perform_now }.to raise_error(RuntimeError, "permanent storage failure")
    end
    expect(output).to include(job_class.name, "permanent storage failure")
    expect(output).not_to include(privacy_email, privacy_token, privacy_marker)
    expect_private_serialization(job)
  end
end
