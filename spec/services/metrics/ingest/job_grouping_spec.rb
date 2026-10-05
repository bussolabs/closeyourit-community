# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Versioned background job grouping" do
  let(:job) do
    { "schema_version" => 1, "framework" => "active_job", "name" => "CheckoutJob", "queue" => "orders",
      "measurement" => "duration", "attempt_outcome" => "success", "terminal" => true }
  end
  let(:payload) { { "kind" => "performance_issue", "subtype" => "slow_job", "label" => "CheckoutJob", "contexts" => { "job" => job } } }

  def normalize(context = job, wire = payload)
    Metrics::Ingest::Normalize.call(payload: wire.merge("contexts" => { "job" => context }))
  end

  it "separates framework, job name, queue and measurement" do
    %w[framework name queue measurement].zip(%w[sidekiq MailJob default queue_wait]).each do |key, value|
      expect(normalize(job.merge(key => value)).signature).not_to eq(normalize.signature)
    end
    expect(normalize.title).to eq("CheckoutJob")
  end

  it "does not split groups by attempt identity, timing or observed outcome" do
    changed = job.merge("job_id" => "another", "attempt" => 4, "retry_count" => 2, "duration_ms" => 900,
      "attempt_outcome" => "retry", "terminal" => false)
    expect(normalize(changed).signature).to eq(normalize.signature)
  end

  it "keeps legacy signatures exact for absent, future, malformed and incomplete contexts" do
    legacy = Metrics::Ingest::Normalize.call(payload: payload.except("contexts")).signature
    [ nil, [], {}, job.merge("schema_version" => 2), job.merge("queue_wait_ms" => 5), job.except("measurement") ].each do |context|
      expect(normalize(context).signature).to eq(legacy)
    end
    expect(legacy).to eq("performance_issue\nslow_job")
  end

  it "retains the original kind and subtype boundaries" do
    python = payload.merge("kind" => "slow_method", "subtype" => nil, "label" => "celery.task.duration.CheckoutJob")
    expect(normalize(job.merge("framework" => "celery"), python).signature).not_to eq(normalize.signature)
    expect(normalize(job, payload.merge("subtype" => "job_queue_latency")).signature).not_to eq(normalize.signature)
  end

  it "does not apply a job context to unrelated metric types" do
    sql = payload.merge("kind" => "slow_query", "sql" => "SELECT 1")
    expect(normalize(job, sql).signature).to eq("slow_query\nSELECT <n>")
  end

  it "scrubs sensitive grouping text before storing the new signature" do
    result = normalize(job.merge("name" => "person@example.test"))
    expect(result.signature).not_to include("person@example.test")
    expect(result.title).not_to include("person@example.test")
  end
end

RSpec.describe "Job samples persisted through the existing metric pipeline" do
  let(:project) { create(:project) }
  let(:job) do
    { "schema_version" => 1, "framework" => "active_job", "name" => "CheckoutJob", "queue" => "orders",
      "measurement" => "duration", "attempt_outcome" => "success", "terminal" => true }
  end

  def record(target, context)
    payload = { "sample_id" => SecureRandom.uuid, "kind" => "performance_issue", "subtype" => "slow_job",
      "label" => "CheckoutJob", "duration_ms" => 12, "occurred_at" => Time.current.iso8601 }
    payload["contexts"] = { "job" => context } if context
    expect(Metrics::Ingest::Record.call(project: target, payload: payload)).to be_ok
  end

  it "keeps historical groups intact while isolating new queues and tenants" do
    record(project, nil)
    historical = project.metric_groups.sole
    record(project, job)
    record(project, job.merge("attempt" => 2))
    record(project, job.merge("queue" => "other"))
    other = create(:project)
    record(other, job)
    expect(project.metric_groups.count).to eq(3)
    expect(historical.reload.samples_count).to eq(1)
    expect(project.metric_samples.count).to eq(4)
    expect(other.metric_groups.sole.samples_count).to eq(1)
    contexts = project.metric_samples.order(:created_at).map { |sample| sample.payload.dig("contexts", "job") }
    expect(contexts.compact.size).to eq(3)
    expect(contexts.compact.first).to eq(job)
  end
end
