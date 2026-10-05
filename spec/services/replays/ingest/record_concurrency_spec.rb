# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CYRA-793 — il recorder manda le finestre a lotti e la coda :ingest le lavora in parallelo: due job
# della STESSA registrazione leggono la riga insieme, ognuno somma il proprio contributo alla copia che
# ha in mano e l'ultimo che salva cancella l'altro. Qui la concorrenza e' vera (due connessioni
# PostgreSQL, niente transazione di prova), perche' e' l'unica che mette alla prova il lock di riga.
RSpec.describe Replays::Ingest::Record, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization:) }

  after do
    # Niente transazione di prova: i file caricati vanno buttati a mano, o restano nel database di
    # prova a sporcare i conteggi di chi misura gli allegati senza aggancio.
    Replays::Session.where(project_id: project.id).find_each { |session| session.chunks.purge }
    organization.destroy! if organization.persisted?
  end

  def chunk(over = {})
    { "replay_session_id" => "sess-1", "seq" => 0, "started_at" => 5.minutes.ago.iso8601,
      "environment" => "production", "events" => [ { "type" => 2 } ] }.merge(over)
  end

  # Fa entrare entrambe le lavorazioni nella sezione critica prima che una qualsiasi salvi: senza
  # barriera i due job si succederebbero e la race non si vedrebbe mai.
  def con_due_lavorazioni_in_parallelo(payloads)
    in_attesa = 0
    mutex = Mutex.new
    barriera = ConditionVariable.new

    allow_any_instance_of(Replays::Session).to receive(:append_chunks!).and_wrap_original do |original, *args, **kwargs|
      mutex.synchronize do
        in_attesa += 1
        barriera.broadcast
        barriera.wait(mutex) while in_attesa < payloads.size
      end
      original.call(*args, **kwargs)
    end

    threads = payloads.map do |payload|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(project: Projects::Project.find(project.id), chunks: [ payload ])
        end
      end
    end

    Timeout.timeout(20) { threads.map(&:value) }
  ensure
    threads&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "conserva entrambi i contributi quando due finestre arrivano sulla stessa registrazione gia' aperta" do
    described_class.call(project:, chunks: [ chunk("seq" => 0, "path" => "/home") ])

    results = con_due_lavorazioni_in_parallelo([
      chunk("seq" => 1, "path" => "/a"),
      chunk("seq" => 2, "path" => "/b")
    ])

    expect(results).to all(be_ok)
    session = project.replay_sessions.sole
    expect(session.events_count).to eq(3)
    expect(session.chunks.count).to eq(3)
    expect(session.pages).to contain_exactly("/home", "/a", "/b")
    expect(session.last_path).to be_in([ "/a", "/b" ])
    expect(session.entry_path).to eq("/home")
    expect(session.ended_at).to be_present
    expect(session.duration_ms).to be > 0
  end

  it "apre una sola registrazione e tiene entrambe le finestre quando nessuno l'ha ancora creata" do
    results = con_due_lavorazioni_in_parallelo([
      chunk("seq" => 0, "path" => "/a", "user" => "acc-42"),
      chunk("seq" => 1, "path" => "/b", "user" => "acc-42")
    ])

    expect(results).to all(be_ok)
    session = project.replay_sessions.sole
    expect(session.events_count).to eq(2)
    expect(session.chunks.count).to eq(2)
    expect(session.pages).to contain_exactly("/a", "/b")
    expect(session.user_hash).to eq(Digest::SHA256.hexdigest("acc-42")[0, 16])
  end
end
