# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Ingest::Record, "tracciamento fonte (sdk)", type: :service do
  let(:project) { create(:project) }

  def payload(sdk: { "name" => "closeyourit-ruby", "version" => "0.4.0" })
    {
      "event_id" => SecureRandom.hex(8),
      "level" => "error",
      "timestamp" => Time.current.to_f,
      "exception" => { "values" => [ {
        "type" => "RuntimeError", "value" => "boom",
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => "call", "in_app" => true } ] }
      } ] }
    }.tap { |p| p["sdk"] = sdk if sdk }
  end

  it "registra la fonte col nome e la versione dell'sdk" do
    described_class.call(project:, payload: payload)

    source = project.sources.find_by!(tool_code: "closeyourit-ruby")
    expect(source.version).to eq("0.4.0")
    expect(source.events_count).to eq(1)
  end

  it "un secondo evento con versione nuova aggiorna versione e contatore della fonte" do
    described_class.call(project:, payload: payload(sdk: { "name" => "closeyourit-ruby", "version" => "0.4.0" }))
    described_class.call(project:, payload: payload(sdk: { "name" => "closeyourit-ruby", "version" => "0.5.0" }))

    source = project.sources.find_by!(tool_code: "closeyourit-ruby")
    expect(source.version).to eq("0.5.0")
    expect(source.events_count).to eq(2)
  end

  # CYRA-64: l'ingest alimenta anche la cronologia versioni (projects_source_versions), una riga per
  # versione vista — dall'optin al passaggio alla successiva.
  it "storicizza le versioni viste: un upgrade dell'sdk apre una seconda riga di cronologia" do
    described_class.call(project:, payload: payload(sdk: { "name" => "closeyourit-ruby", "version" => "0.4.0" }))
    described_class.call(project:, payload: payload(sdk: { "name" => "closeyourit-ruby", "version" => "0.5.0" }))

    source = project.sources.find_by!(tool_code: "closeyourit-ruby")
    expect(source.versions.chronological.pluck(:version)).to eq(%w[0.4.0 0.5.0])
  end

  it "nessun sdk nel payload → nessuna fonte registrata" do
    expect { described_class.call(project:, payload: payload(sdk: nil)) }
      .not_to change(project.sources, :count)
  end

  it "sdk.name scrubbato dal client ([FILTERED]) → nessuna fonte placeholder registrata" do
    expect { described_class.call(project:, payload: payload(sdk: { "name" => "[FILTERED]", "version" => "0.4.0" })) }
      .not_to change(project.sources, :count)
  end

  # CYRA-42: la fonte è un upsert atomico autonomo che NON deve stare nella transazione del gruppo
  # (500 eventi/sec dello stesso SDK farebbero la coda sulla singola riga projects_sources, tenendo il
  # lock fino al commit di una transazione già contesa su bump_group!). Prova comportamentale: se track!
  # solleva, l'evento resta persistito → la registrazione della fonte è FUORI dalla transazione.
  it "registra la fonte FUORI dalla transazione del gruppo: se track! fallisce, l'evento resta persistito" do
    allow(Projects::Source).to receive(:track!).and_raise(ActiveRecord::StatementInvalid, "lock timeout")

    expect { described_class.call(project:, payload: payload) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(project.error_events.count).to eq(1)
  end
end
