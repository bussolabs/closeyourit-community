# frozen_string_literal: true

require "rails_helper"

# CYRA-1210 — jobs queued before the release carry the raw batch: the worker still saves and scrubs it,
# and a raw item is saved exactly like the same item scrubbed before the queue.
RSpec.describe "Ingest jobs queued before the queue scrub" do
  let(:project) { create(:project) }
  let(:email) { "queued-1210@example.test" }

  it "saves and scrubs a raw log batch" do
    raw = [
      { "event_id" => "raw-log", "level" => "error", "message" => "User #{email} token=queued-secret",
        "attributes" => { "email" => email, "area" => "signup" }, "unused" => email },
      { "event_id" => "scrubbed-log", "level" => "error", "message" => "User #{email} token=queued-secret",
        "attributes" => { "email" => email, "area" => "signup" } }
    ]
    Logs::IngestJob.perform_now(project_id: project.id,
                                payload: [ raw.first, Logs::Ingest::Scrub.call(payload: raw.last) ])

    entries = project.logs_entries.order(:event_id).to_a
    expect(entries.map(&:event_id)).to eq(%w[raw-log scrubbed-log])
    expect(entries.map(&:message).uniq).to eq([ "User [FILTERED] token=[FILTERED]" ])
    expect(entries.map(&:data).uniq).to eq([ { "email" => "[FILTERED]", "area" => "signup" } ])
    expect(entries.map(&:fingerprint).uniq.size).to eq(1)
  end

  it "saves and scrubs a raw metric batch into the same group as a scrubbed one" do
    sql = "SELECT * FROM users WHERE email = '#{email}' /*application='Shop',controller='users'*/"
    raw = { "kind" => "slow_query", "duration_ms" => 12, "sql" => sql, "occurred_at" => Time.current.iso8601,
            "context" => { "user_email" => email } }
    Metrics::IngestJob.perform_now(project_id: project.id, payload: [
      raw.merge("sample_id" => "raw-sample"),
      Metrics::Ingest::Scrub.call(payload: raw.merge("sample_id" => "scrubbed-sample"))
    ])

    samples = project.metric_samples.to_a
    expect(samples.size).to eq(2)
    expect(samples.map(&:group_id).uniq.size).to eq(1)
    expect(samples.map(&:payload).to_json).not_to include(email)
    # The signature the worker computed before the queue scrub, so stored groups keep receiving samples.
    signature = "slow_query\nSELECT * FROM users WHERE email = <str> /*application=<str>,controller=<str>*/"
    expect(samples.first.group.fingerprint).to eq(Metrics::Fingerprint.call(signature: signature))
  end

  it "saves and scrubs a raw pageview batch" do
    raw = { "event_id" => "raw-visit", "hostname" => "example.test", "path" => "/checkout?email=#{email}",
            "referrer" => "https://referrer.test/landing?token=queued-secret", "occurred_at" => Time.current.iso8601,
            "properties" => { "email" => email, "plan" => "pro" } }
    Analytics::IngestJob.perform_now(project_id: project.id, context: { visitor_hash: "a" * 64 }, payload: [ raw ])

    row = project.analytics_pageviews.sole
    expect(row.path).to eq("/checkout")
    expect(row.referrer_host).to eq("referrer.test")
    expect(row.properties).to eq("plan" => "pro")
  end
end
