# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ingest queue scrubbing" do
  let(:email) { "customer-1210@example.test" }
  let(:secret) { "private-secret-1210" }

  it "preserves log linkage and normalization while discarding unused fields" do
    trace = SecureRandom.uuid
    raw = { "event_id" => "log-id", "timestamp" => 1_790_000_000_000,
            "message" => "[#{trace}] User #{email} token=#{secret}",
            "attributes" => { "nested" => [ email, { "ip_address" => "203.0.113.42" } ] },
            "unused" => secret, "sdk" => { "name" => "ruby", "version" => "1.2", "user" => secret } }
    original = raw.deep_dup
    cleaned = Logs::Ingest::Scrub.call(payload: raw)
    normalized = Logs::Ingest::Normalize.call(payload: cleaned)

    expect(raw).to eq(original)
    expect(cleaned.to_json).not_to include(email, secret, "203.0.113.42", "unused")
    expect(cleaned["timestamp"]).to eq(raw["timestamp"])
    expect(normalized.trace_id).to eq(trace)
    expect(normalized.trace_id_extracted).to be(true)
    expect(normalized.event_id).to eq("log-id")
    expect(normalized.sdk_name).to eq("ruby")
    expect(normalized).to eq(Logs::Ingest::Normalize.call(payload: raw))
  end

  it "preserves SQL grouping, duration and technical correlation IDs across the queue" do
    raw = { "kind" => "slow_query", "sample_id" => "sample-id", "duration_ms" => "12.5",
            "occurred_at" => 1_790_000_000_000, "trace_id" => "trace-id", "span_id" => "span-id",
            "sql" => "SELECT * FROM users WHERE email = '#{email}' AND token = $tag$#{secret}$tag$ AND ssn = 123456789",
            "context" => { "nested" => [ email ], "http_url" => "https://user:#{secret}@example.test/path?key=#{secret}" } }
    cleaned = Metrics::Ingest::Scrub.call(payload: raw)
    normalized = Metrics::Ingest::Normalize.call(payload: cleaned)

    expect(cleaned.to_json).not_to include(email, secret, "123456789")
    expect(cleaned).to include("span_id" => "span-id", "trace_id" => "trace-id", "duration_ms" => "12.5")
    expect(cleaned.dig("context", "http_url")).to eq("https://example.test/path")
    expect(normalized).to eq(Metrics::Ingest::Normalize.call(payload: raw))
    expect(normalized.signature).to eq("slow_query\nSELECT * FROM users WHERE email = <str> AND token = <str> AND ssn = <n>")
    expect(Metrics::Ingest::Scrub.call(payload: cleaned)).to eq(cleaned)
  end

  it "keeps analytics dates and event IDs while cleaning every retained text field" do
    raw = { "event_id" => "visit-id", "occurred_at" => 1_790_000_000_000,
            "hostname" => "example.test", "path" => "/people/#{email}?token=#{secret}#private",
            "referrer" => "https://user:#{secret}@referrer.test/private?token=#{secret}",
            "name" => "event #{email}", "utm_campaign" => email, "environment" => email,
            "properties" => { "email" => email, "phone" => "+39 333 1234567", "plan" => "pro" },
            "user_agent" => secret, "ip" => "203.0.113.42" }
    cleaned = Analytics::Ingest::Scrub.call(payload: raw)

    expect(cleaned.to_json).not_to include(email, secret, "203.0.113.42", "+39 333 1234567")
    expect(cleaned).to include("event_id" => "visit-id", "occurred_at" => raw["occurred_at"])
    expect(cleaned["referrer"]).to eq("https://referrer.test")
    expect(cleaned["properties"]).to eq("plan" => "pro")
    expect(Analytics::Ingest::Scrub.call(payload: cleaned)).to eq(cleaned)
  end

  it "scrubs personal text in SQL comments as well as literals" do
    cleaned = Metrics::Ingest::Scrub.call(payload: {
      "kind" => "slow_query", "sql" => "SELECT 1 -- #{email} token=#{secret}"
    })
    expect(cleaned["sql"]).not_to include(email, secret)
    expect(cleaned["sql"]).to include("SELECT <n>")
  end

  it "does not change a SQL grouping placeholder next to a sensitive column name" do
    raw = { "kind" => "slow_query", "sql" => "SELECT * FROM users WHERE token='secret' AND id=42" }
    normalized = Metrics::Ingest::Normalize.call(payload: Metrics::Ingest::Scrub.call(payload: raw))
    expect(normalized.signature).to eq("slow_query\nSELECT * FROM users WHERE token=<str> AND id=<n>")
  end

  it "scrubs percent-encoded email addresses in page paths" do
    cleaned = Analytics::Ingest::Scrub.call(payload: {
      "hostname" => "example.test", "path" => "/people/private-1210%40example.test/profile"
    })
    expect(cleaned["path"]).to eq("/people/[FILTERED]/profile")
  end

  # Unexpected fields: logs and visits keep only the fields the worker reads, so an unknown field never
  # reaches the queue. A metric sample is stored whole as diagnostics, so unknown fields stay, scrubbed.
  it "drops unexpected log and visit fields and keeps unexpected metric fields scrubbed" do
    extra = { "custom" => { "note" => "Contact #{email}", "user_email" => email, "count" => 3 } }
    log = Logs::Ingest::Scrub.call(payload: { "message" => "hello" }.merge(extra))
    visit = Analytics::Ingest::Scrub.call(payload: { "hostname" => "example.test", "path" => "/" }.merge(extra))
    metric = Metrics::Ingest::Scrub.call(payload: { "kind" => "slow_method", "label" => "Jobs#run" }.merge(extra))

    expect(log).to eq("message" => "hello")
    expect(visit).to eq("hostname" => "example.test", "path" => "/", "properties" => {})
    expect(metric["custom"]).to eq("note" => "Contact [FILTERED]", "user_email" => "[FILTERED]", "count" => 3)
  end

  # Stored groups: the queue scrub must not move a sample to a new group. Each signature is the one the
  # worker computed from the raw sample before the queue scrub existed.
  {
    "query log tags" => [ { "kind" => "slow_query",
                            "sql" => "SELECT * FROM orders WHERE id = 42 /*application='Shop',controller='orders',action='show'*/" },
                          "slow_query\nSELECT * FROM orders WHERE id = <n> /*application=<str>,controller=<str>,action=<str>*/" ],
    "a slow method" => [ { "kind" => "slow_method", "label" => "Billing::Invoice#total" }, "slow_method\nBilling::Invoice#total" ],
    "an N+1 query" => [ { "kind" => "performance_issue", "subtype" => "n_plus_one",
                          "sql" => "SELECT * FROM items WHERE cart_id = 7", "source" => "app/models/cart.rb:12" },
                        "performance_issue\nn_plus_one SELECT * FROM items WHERE cart_id = <n> app/models/cart.rb:12" ],
    "a slow request" => [ { "kind" => "performance_issue", "subtype" => "slow_request", "route" => "GET /users/:id" },
                          "performance_issue\nslow_request GET /users/:id" ]
  }.each do |name, (raw, signature)|
    it "keeps the stored grouping of #{name}" do
      normalized = Metrics::Ingest::Normalize.call(payload: Metrics::Ingest::Scrub.call(payload: raw))
      expect(normalized.signature).to eq(signature)
    end
  end
end
