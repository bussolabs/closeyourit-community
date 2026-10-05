# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Ingest::Record, "tracciamento fonte (sdk)" do
  let(:project) { create(:project) }

  def item(sdk: { "name" => "closeyourit-ruby", "version" => "0.4.0" }, **over)
    { "event_id" => SecureRandom.uuid, "message" => "hello", "level" => "info",
      "timestamp" => "2026-06-28T10:00:00Z" }.merge(over).tap { |i| i["sdk"] = sdk if sdk }
  end

  it "registra la fonte una sola volta per batch (log alto-volume)" do
    described_class.call(project:, payload: [ item, item, item ])

    source = project.sources.find_by!(tool_code: "closeyourit-ruby")
    expect(source.version).to eq("0.4.0")
    expect(source.events_count).to eq(1) # una registrazione per batch, non per riga
  end

  it "nessun sdk negli item → nessuna fonte" do
    expect { described_class.call(project:, payload: [ item(sdk: nil), item(sdk: nil) ]) }
      .not_to change(project.sources, :count)
  end

  # CYRA-42: nei log la fonte è già registrata DOPO l'insert_all (fuori da qualsiasi transazione).
  # Guard di regressione: se track! solleva, le entry restano persistite → la fonte non è mai in una
  # transazione che tenga il lock sulla riga hot projects_sources.
  it "registra la fonte dopo l'insert (fuori transazione): se track! fallisce, le entry restano persistite" do
    allow(Projects::Source).to receive(:track!).and_raise(ActiveRecord::StatementInvalid, "lock timeout")

    expect { described_class.call(project:, payload: [ item ]) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(Logs::Entry.where(project_id: project.id).count).to eq(1)
  end
end
