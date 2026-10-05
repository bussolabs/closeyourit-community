# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Ingest::Record, "tracciamento fonte (sdk)" do
  let(:project) { create(:project) }

  def payload(sdk: { "name" => "closeyourit-ruby", "version" => "0.4.0" }, **over)
    {
      "kind" => "slow_query",
      "sample_id" => SecureRandom.uuid,
      "duration_ms" => 120.0,
      "occurred_at" => Time.current.iso8601,
      "environment" => "production",
      "sql" => "SELECT * FROM users WHERE id = 42"
    }.merge(over).tap { |p| p["sdk"] = sdk if sdk }
  end

  it "registra la fonte dall'sdk del campione" do
    described_class.call(project:, payload: payload)

    source = project.sources.find_by!(tool_code: "closeyourit-ruby")
    expect(source.version).to eq("0.4.0")
    expect(source.events_count).to eq(1)
  end

  it "nessun sdk → nessuna fonte" do
    expect { described_class.call(project:, payload: payload(sdk: nil)) }
      .not_to change(project.sources, :count)
  end

  # CYRA-42: Source.track! è un upsert atomico autonomo e non deve stare nella transazione del gruppo
  # (contesa di lock sulla singola riga projects_sources sotto burst). Prova comportamentale: se track!
  # solleva, il campione resta persistito → la registrazione della fonte è FUORI dalla transazione.
  it "registra la fonte FUORI dalla transazione del gruppo: se track! fallisce, il campione resta persistito" do
    allow(Projects::Source).to receive(:track!).and_raise(ActiveRecord::StatementInvalid, "lock timeout")

    expect { described_class.call(project:, payload: payload) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(project.metric_samples.count).to eq(1)
  end
end
