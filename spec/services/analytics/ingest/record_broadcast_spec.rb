# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime di Analytics::Ingest::Record: dopo l'insert_all dei pageview emette un
# page-refresh Turbo sullo stream analytics del progetto, SOLO se ci sono righe realmente inserite
# (batch vuoto o interamente duplicato → nessun refresh).
RSpec.describe Analytics::Ingest::Record, "broadcasts", type: :service do
  let(:project) { create(:project) }
  let(:context) { { visitor_hash: Digest::SHA256.hexdigest("v") } }
  let(:stream) { Realtime::Streams.analytics(project) }

  def item(over = {})
    { "event_id" => SecureRandom.uuid, "hostname" => "www.example.test", "path" => "/foo" }.merge(over)
  end

  it "page-refresh Turbo sullo stream del progetto quando ci sono righe inserite" do
    expect { described_class.call(project:, payload: [ item ], context:) }
      .to have_broadcasted_to(stream).with(a_string_including('action="refresh"'))
  end

  it "NON broadcasta se il batch non ha item validi" do
    expect { described_class.call(project:, payload: [], context:) }
      .not_to have_broadcasted_to(stream)
  end

  it "NON broadcasta se tutte le righe sono duplicati (0 inserted, idempotenza)" do
    dup = item
    described_class.call(project:, payload: [ dup ], context:)
    expect { described_class.call(project:, payload: [ dup ], context:) }
      .not_to have_broadcasted_to(stream)
  end
end
