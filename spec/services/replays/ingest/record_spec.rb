# frozen_string_literal: true

require "rails_helper"

RSpec.describe Replays::Ingest::Record, type: :service do
  let(:project) { create(:project) }

  def chunk(over = {})
    { "replay_session_id" => "sess-1", "seq" => 0, "started_at" => Time.current.iso8601,
      "environment" => "production", "events" => [ { "type" => 2 } ] }.merge(over)
  end

  it "crea una sessione e allega i chunk gzippati" do
    result = described_class.call(project:, chunks: [ chunk("seq" => 0), chunk("seq" => 1) ])

    expect(result).to be_ok
    session = project.replay_sessions.sole
    expect(session.replay_session_id).to eq("sess-1")
    expect(session.environment).to eq("production")
    expect(session.chunks.count).to eq(2)
    expect(session.events_count).to eq(2)
  end

  it "è idempotente sulla sessione: chunk successivi si agganciano alla stessa" do
    described_class.call(project:, chunks: [ chunk("seq" => 0) ])
    expect { described_class.call(project:, chunks: [ chunk("seq" => 1) ]) }
      .not_to change(Replays::Session, :count)
    expect(project.replay_sessions.sole.chunks.count).to eq(2)
  end

  it "raggruppa chunk di sessioni diverse in sessioni distinte" do
    described_class.call(project:, chunks: [
      chunk("replay_session_id" => "a"), chunk("replay_session_id" => "b")
    ])
    expect(project.replay_sessions.pluck(:replay_session_id)).to contain_exactly("a", "b")
  end

  it "scarta i chunk senza id o senza eventi" do
    described_class.call(project:, chunks: [ chunk("events" => []), chunk("replay_session_id" => "") ])
    expect(project.replay_sessions.count).to eq(0)
  end

  # CYRA-793 — i byte salgono PRIMA dell'aggancio (l'upload sta fuori dal lock di riga): se il lotto
  # si interrompe a metà restano file caricati che nessuna sessione nomina, e ActiveStorage non li pota.
  describe "lotto interrotto a metà" do
    it "non lascia file caricati senza registrazione quando un caricamento fallisce" do
      chiamate = 0
      allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_wrap_original do |original, **kwargs|
        chiamate += 1
        raise "servizio di archiviazione irraggiungibile" if chiamate == 2

        original.call(**kwargs)
      end

      expect do
        expect { described_class.call(project:, chunks: [ chunk("seq" => 0), chunk("seq" => 1) ]) }
          .to raise_error("servizio di archiviazione irraggiungibile")
      end.not_to change(ActiveStorage::Blob.unattached, :count)
    end

    it "non lascia file caricati senza registrazione quando l'aggancio fallisce" do
      allow_any_instance_of(Replays::Session).to receive(:append_chunks!).and_raise("riga bloccata")

      expect do
        expect { described_class.call(project:, chunks: [ chunk("seq" => 0), chunk("seq" => 1) ]) }
          .to raise_error("riga bloccata")
      end.not_to change(ActiveStorage::Blob.unattached, :count)
    end

    it "non tocca i file gia' agganciati da un invio precedente" do
      described_class.call(project:, chunks: [ chunk("seq" => 0) ])
      allow_any_instance_of(Replays::Session).to receive(:append_chunks!).and_raise("riga bloccata")

      expect do
        expect { described_class.call(project:, chunks: [ chunk("seq" => 1) ]) }.to raise_error("riga bloccata")
      end.not_to change(ActiveStorage::Blob.unattached, :count)
      expect(project.replay_sessions.sole.chunks.count).to eq(1)
    end
  end

  describe "arricchimento comportamento (path/user)" do
    it "estrae entry_path, last_path, pages distinte e user_hash" do
      described_class.call(project:, chunks: [
        chunk("seq" => 0, "path" => "/home",     "user" => "acc-42"),
        chunk("seq" => 1, "path" => "/checkout", "user" => "acc-42"),
        chunk("seq" => 2, "path" => "/home",     "user" => "acc-42") # ripetuta → non duplicata
      ])

      session = project.replay_sessions.sole
      expect(session.entry_path).to eq("/home")
      expect(session.last_path).to eq("/home")
      expect(session.pages).to contain_exactly("/home", "/checkout")
      expect(session.pages_count).to eq(2)
      expect(session.user_hash).to eq(Digest::SHA256.hexdigest("acc-42")[0, 16])
    end

    it "accumula pagine e aggiorna last_path su batch successivi (entry_path/user_hash invariati)" do
      described_class.call(project:, chunks: [ chunk("seq" => 0, "path" => "/a", "user" => "u1") ])
      described_class.call(project:, chunks: [ chunk("seq" => 1, "path" => "/b") ])

      session = project.replay_sessions.sole
      expect(session.entry_path).to eq("/a")
      expect(session.last_path).to eq("/b")
      expect(session.pages).to contain_exactly("/a", "/b")
      expect(session.user_hash).to eq(Digest::SHA256.hexdigest("u1")[0, 16]) # non sovrascritto
    end

    it "strippa query string/hash dal path (difesa)" do
      described_class.call(project:, chunks: [ chunk("path" => "/search?q=segreto#top") ])
      expect(project.replay_sessions.sole.entry_path).to eq("/search")
    end

    it "lascia i campi nil quando i chunk non portano path/user (SDK vecchio)" do
      described_class.call(project:, chunks: [ chunk ]) # nessun path/user
      session = project.replay_sessions.sole
      expect(session.entry_path).to be_nil
      expect(session.user_hash).to be_nil
      expect(session.pages).to eq([])
    end
  end
end
