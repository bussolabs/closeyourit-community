# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime di Logs::Ingest::Record (CYRA-57). Il vecchio contratto renderizzava un partial +
# scriveva su Action Cable PER OGNI riga inserita (fino a 1000 render+cable per batch), bloccando il
# worker :ingest sotto burst. Ora Record emette, DOPO l'insert_all (già committato), UN SOLO page-refresh
# Turbo (action="refresh") per batch sullo stream log dell'org — throttlato in Logs::Broadcast. Nessun
# HTML nel worker: ogni viewer ri-fetcha la PROPRIA index (coi suoi filtri) e morpha. I duplicati
# skippati da ON CONFLICT non tornano nel RETURNING → niente refresh a vuoto. Lo stream è org-prefissato
# da Realtime::Streams → isolamento tenant implicito nel nome.
RSpec.describe Logs::Ingest::Record, "broadcasts", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:logs_stream) { Realtime::Streams.logs(organization) }

  def payload(overrides = {})
    { "event_id" => SecureRandom.uuid, "message" => "disk almost full", "level" => "info",
      "timestamp" => "2026-06-28T10:00:00Z" }.merge(overrides)
  end

  def record(input) = described_class.call(project:, payload: input)

  describe "stream log dell'org" do
    it "un solo page-refresh Turbo (action=refresh) su una entry inserita" do
      expect { record(payload) }.to have_broadcasted_to(logs_stream)
        .with(a_string_including('action="refresh"'))
    end

    it "batch di 3 entry distinte → UN SOLO refresh (non un broadcast per riga)" do
      expect { record([ payload, payload, payload ]) }
        .to have_broadcasted_to(logs_stream).once
    end

    it "burst da 1000 item → UN SOLO refresh (il worker non fa 1000 render+cable)" do
      big = Array.new(1000) { payload }
      expect { record(big) }.to have_broadcasted_to(logs_stream).once
    end

    it "scarta gli item senza message → refresh solo se resta almeno una entry valida" do
      expect { record([ payload("message" => ""), payload ]) }
        .to have_broadcasted_to(logs_stream).once
    end

    it "batch interamente scartato (nessuna entry valida) → nessun refresh" do
      expect { record([ payload("message" => ""), payload("message" => "   ") ]) }
        .not_to have_broadcasted_to(logs_stream)
    end

    it "lista vuota → nessun broadcast" do
      expect { record([]) }.not_to have_broadcasted_to(logs_stream)
    end
  end

  describe "idempotenza (duplicati skippati non rinnovano il refresh)" do
    it "stesso event_id alla seconda chiamata (nulla inserito) → nessun refresh" do
      fixed = payload("event_id" => "dup-1")
      record(fixed)
      expect { record(fixed) }.not_to have_broadcasted_to(logs_stream)
    end

    it "event_id ripetuto nello stesso batch → un solo refresh" do
      fixed = payload("event_id" => "same")
      expect { record([ fixed, fixed ]) }.to have_broadcasted_to(logs_stream).once
    end
  end

  describe "isolamento tenant" do
    it "non broadcasta sullo stream log di un'ALTRA organizzazione" do
      other = Realtime::Streams.logs(create(:organization))
      expect { record(payload) }.not_to have_broadcasted_to(other)
    end
  end
end
