# frozen_string_literal: true

require "rails_helper"

# Correlazione errore ↔ session replay: il browser SDK mette l'id della sessione in
# contexts.replay.replay_id; Normalize lo estrae e Record lo persiste su errors_events.replay_session_id.
RSpec.describe "Errors ingest — replay correlation", type: :service do
  let(:project) { create(:project) }

  def payload(over = {})
    {
      "event_id" => SecureRandom.hex(16),
      "level" => "error",
      "timestamp" => Time.current.to_f,
      "exception" => { "values" => [ {
        "type" => "TypeError", "value" => "boom",
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => "call", "in_app" => true } ] }
      } ] }
    }.merge(over)
  end

  describe Errors::Ingest::Normalize do
    it "estrae replay_session_id da contexts.replay.replay_id" do
      normalized = described_class.call(
        payload: payload("contexts" => { "replay" => { "replay_id" => "sess-xyz" } })
      )
      expect(normalized.replay_session_id).to eq("sess-xyz")
    end

    it "replay_session_id nil senza contexts.replay valido" do
      expect(described_class.call(payload: payload).replay_session_id).to be_nil
      expect(described_class.call(payload: payload("contexts" => { "replay" => "x" })).replay_session_id).to be_nil
    end
  end

  describe Errors::Ingest::Record do
    it "persiste replay_session_id sull'occorrenza" do
      result = described_class.call(
        project:, payload: payload("contexts" => { "replay" => { "replay_id" => "sess-xyz" } })
      )
      expect(result).to be_ok
      expect(result.value.replay_session_id).to eq("sess-xyz")
    end

    it "lascia replay_session_id nil quando l'errore non ha una sessione replay" do
      result = described_class.call(project:, payload: payload)
      expect(result.value.replay_session_id).to be_nil
    end
  end
end
