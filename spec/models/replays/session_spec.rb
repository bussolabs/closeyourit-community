# frozen_string_literal: true

require "rails_helper"

RSpec.describe Replays::Session, type: :model do
  let(:project) { create(:project) }

  it "richiede replay_session_id e started_at" do
    session = Replays::Session.new(project:)
    expect(session).not_to be_valid
    expect(session.errors[:replay_session_id]).to be_present
    expect(session.errors[:started_at]).to be_present
  end

  it "unicità di replay_session_id nello scope del progetto" do
    project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current)
    dup = project.replay_sessions.build(replay_session_id: "s1", started_at: Time.current)
    expect(dup).not_to be_valid
  end

  it "lo stesso id è ammesso su progetti diversi" do
    other = create(:project)
    project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current)
    ok = other.replay_sessions.build(replay_session_id: "s1", started_at: Time.current)
    expect(ok).to be_valid
  end

  describe "#append_chunks!" do
    # I blob arrivano già caricati (CYRA-793): l'upload avviene nell'ingest, fuori dal lock.
    def entry(nome, events_count:)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(nome), filename: "s1-#{nome}.json.gz", content_type: "application/gzip"
      )
      { blob: blob, events_count: events_count }
    end

    it "allega i chunk in un solo attach e aggiorna events_count / ended_at / duration_ms" do
      started = Time.current
      session = project.replay_sessions.create!(replay_session_id: "s1", started_at: started)
      ended = started + 5.seconds

      session.append_chunks!([ entry("a", events_count: 2), entry("b", events_count: 1) ], ended_at: ended)

      expect(session.chunks.count).to eq(2)
      expect(session.events_count).to eq(3)
      expect(session.ended_at).to be_within(1.second).of(ended)
      expect(session.duration_ms).to eq(5000)
    end

    it "accumula events_count su append successivi" do
      session = project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current)
      session.append_chunks!([ entry("a", events_count: 2) ])
      session.append_chunks!([ entry("b", events_count: 4) ])

      expect(session.chunks.count).to eq(2)
      expect(session.events_count).to eq(6)
    end

    it "unisce le pagine visitate al set già salvato e sposta l'ultima pagina" do
      session = project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current)
      session.append_chunks!([ entry("a", events_count: 1) ], paths: [ "/home", "/checkout" ])
      session.append_chunks!([ entry("b", events_count: 1) ], paths: [ "/home", "/grazie" ])

      expect(session.pages).to eq([ "/home", "/checkout", "/grazie" ])
      expect(session.last_path).to eq("/grazie")
    end

    it "non supera il tetto di pagine distinte per sessione" do
      session = project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current)
      troppe = (1..(Replays::Constants::PAGES_MAX + 5)).map { |n| "/p#{n}" }

      session.append_chunks!([ entry("a", events_count: 1) ], paths: troppe)

      expect(session.pages.size).to eq(Replays::Constants::PAGES_MAX)
    end

    # CYRA-793 — due finestre della stessa registrazione elaborate insieme partono da due copie
    # della riga: senza rilettura sotto lock la seconda salva un totale calcolato su dati vecchi.
    it "somma il contributo di una copia letta prima che l'altra salvasse" do
      session = project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current)
      prima = Replays::Session.find(session.id)
      dopo  = Replays::Session.find(session.id)

      prima.append_chunks!([ entry("a", events_count: 2) ], paths: [ "/a" ])
      dopo.append_chunks!([ entry("b", events_count: 4) ], paths: [ "/b" ])

      expect(session.reload.events_count).to eq(6)
      expect(session.chunks.count).to eq(2)
      expect(session.pages).to contain_exactly("/a", "/b")
    end

    it "conserva gli allegati di una copia che aveva gia' letto l'elenco vuoto" do
      session = project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current)
      prima = Replays::Session.find(session.id)
      dopo  = Replays::Session.find(session.id)
      dopo.chunks.blobs.to_a # elenco letto prima che l'altra copia allegasse

      prima.append_chunks!([ entry("a", events_count: 1) ])
      dopo.append_chunks!([ entry("b", events_count: 1) ])

      expect(session.reload.chunks.count).to eq(2)
      expect(session.events_count).to eq(2)
    end
  end
end
