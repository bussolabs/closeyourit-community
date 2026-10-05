# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Ingest::Record do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }

  def payload(overrides = {})
    { "event_id" => SecureRandom.uuid, "message" => "hello", "level" => "info",
      "timestamp" => "2026-06-28T10:00:00Z" }.merge(overrides)
  end

  it "inserisce un singolo log e ritorna il conteggio accettato" do
    result = described_class.call(project: project, payload: payload)
    expect(result).to be_ok
    expect(result.value).to eq(1)
    expect(project.logs_entries.count).to eq(1)
  end

  it "inserisce un array di log in batch" do
    result = described_class.call(project: project, payload: [ payload, payload, payload ])
    expect(result.value).to eq(3)
    expect(project.logs_entries.count).to eq(3)
  end

  it "persiste i campi normalizzati (level enum + attributes scrubbati)" do
    described_class.call(project: project, payload: payload(
      "level" => "error", "message" => "boom", "logger" => "system",
      "attributes" => { "token" => "secret", "ok" => "v" }, "trace_id" => "t-9"
    ))
    entry = project.logs_entries.sole
    expect(entry).to be_level_error
    expect(entry.message).to eq("boom")
    expect(entry.logger_name).to eq("system")
    expect(entry.trace_id).to eq("t-9")
    expect(entry.data).to eq("token" => "[FILTERED]", "ok" => "v")
  end

  # CYRA-345: senza campo strutturato, il trace id viene riconosciuto nel testo e persistito sulla
  # colonna del join, marcato come dedotto dal messaggio.
  it "estrae e persiste il trace id dal messaggio quando manca il campo strutturato" do
    described_class.call(project: project, payload: payload(
      "event_id" => "e1", "message" => "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom", "trace_id" => nil
    ))
    entry = project.logs_entries.sole
    expect(entry.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
    expect(entry.trace_id_extracted).to be(true)
  end

  it "col campo strutturato presente non marca il trace come estratto" do
    described_class.call(project: project, payload: payload(
      "message" => "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom", "trace_id" => "structured"
    ))
    entry = project.logs_entries.sole
    expect(entry.trace_id).to eq("structured")
    expect(entry.trace_id_extracted).to be(false)
  end

  it "è idempotente sullo stesso event_id per progetto (skip duplicati)" do
    fixed = payload("event_id" => "dup-1")
    described_class.call(project: project, payload: fixed)
    result = described_class.call(project: project, payload: fixed)
    expect(project.logs_entries.count).to eq(1)
    expect(result).to be_ok
  end

  it "scrive sempre sul progetto passato (anti-BOLA, ignora project_id nel payload)" do
    other = create(:project)
    described_class.call(project: project, payload: payload("project_id" => other.id))
    expect(project.logs_entries.count).to eq(1)
    expect(other.logs_entries.count).to eq(0)
  end

  it "ignora una lista vuota" do
    result = described_class.call(project: project, payload: [])
    expect(result.value).to eq(0)
  end

  it "deduplica gli event_id ripetuti nello stesso batch" do
    fixed = payload("event_id" => "same")
    described_class.call(project: project, payload: [ fixed, fixed ])
    expect(project.logs_entries.count).to eq(1)
  end

  it "scarta gli item senza message (niente spazzatura via insert_all)" do
    result = described_class.call(project: project, payload: [ payload("message" => ""), payload ])
    expect(result.value).to eq(1)
    expect(project.logs_entries.count).to eq(1)
  end

  it "scarta gli item non-hash (body JSON valido ma malformato)" do
    result = described_class.call(project: project, payload: [ 42, "x", payload ])
    expect(result.value).to eq(1)
    expect(project.logs_entries.count).to eq(1)
  end

  # CYRA-58: il pre-check del controller usa .acceptable?, che deve essere leggero (niente Normalize
  # completa nel thread web) senza divergere dal filtro applicato in fase di persistenza.
  describe ".acceptable?" do
    it "true per un Hash con message, false per non-hash o message assente/blank" do
      expect(described_class.acceptable?(payload)).to be(true)
      expect(described_class.acceptable?(payload("message" => ""))).to be(false)
      expect(described_class.acceptable?(payload("message" => "   "))).to be(false)
      expect(described_class.acceptable?("no")).to be(false)
      expect(described_class.acceptable?(42)).to be(false)
    end

    it "non esegue la Normalize completa (pre-check leggero, resta nel job)" do
      expect(Logs::Ingest::Normalize).not_to receive(:call)
      described_class.acceptable?(payload("attributes" => { "deep" => { "token" => "s" } }))
    end

    it "non diverge dal filtro di persistenza: message di soli null byte scartato da entrambi" do
      item = payload("message" => 0.chr * 2)
      expect(described_class.acceptable?(item)).to be(false)
      result = described_class.call(project: project, payload: [ item ])
      expect(result.value).to eq(0)
      expect(project.logs_entries.count).to eq(0)
    end
  end

  # CYRA-55: i log error/fatal devono valutare le regole di alerting (prima venivano solo scritti).
  # subtype-aware: solo error/fatal accodano l'alert — debug/info/warning restano osservabilità muta.
  describe "alert su log error/fatal (CYRA-55)" do
    it "un log fatal accoda Alerting::EvaluateJob (event_type log_alert, subject Logs::Entry)" do
      expect do
        described_class.call(project: project, payload: payload("level" => "fatal", "message" => "gateway down"))
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "log_alert", subject_type: "Logs::Entry", project_id: project.id))
    end

    it "un log error accoda l'alert col livello error" do
      expect do
        described_class.call(project: project, payload: payload("level" => "error"))
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "log_alert", level: Logs::Entry.levels["error"]))
    end

    it "un log info NON accoda alcun alert (solo error/fatal)" do
      expect do
        described_class.call(project: project, payload: payload("level" => "info"))
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "un batch misto accoda solo per le entry error/fatal" do
      expect do
        described_class.call(project: project, payload: [
          payload("level" => "info"), payload("level" => "fatal"),
          payload("level" => "warning"), payload("level" => "error")
        ])
      end.to have_enqueued_job(Alerting::EvaluateJob).exactly(:twice)
    end

    it "un log fatal duplicato (già ingerito) non riaccoda l'alert" do
      fixed = payload("event_id" => "dup-fatal", "level" => "fatal")
      described_class.call(project: project, payload: fixed)
      expect { described_class.call(project: project, payload: fixed) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    # CYRA-274: un lotto di N log error accodava un EvaluateJob PER RIGA, saturando la coda :alerts.
    # Ora una sola valutazione per livello; il throttle fine resta in Alerting::Evaluate.
    it "un lotto di molti log error accoda UN solo alert, non uno per riga" do
      batch = Array.new(50) { payload("event_id" => SecureRandom.uuid, "level" => "error") }
      expect { described_class.call(project: project, payload: batch) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "log_alert", level: Logs::Entry.levels["error"])).exactly(:once)
    end

    # Le regole log_alert possono essere scoped per ambiente: il collasso NON deve fondere ambienti
    # diversi, o un batch misto perderebbe l'alert di uno dei due (CYRA-274).
    it "un batch con error di ambienti diversi accoda un alert per ciascun ambiente" do
      expect do
        described_class.call(project: project, payload: [
          payload("event_id" => SecureRandom.uuid, "level" => "error", "environment" => "production"),
          payload("event_id" => SecureRandom.uuid, "level" => "error", "environment" => "staging")
        ])
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "log_alert", level: Logs::Entry.levels["error"])).exactly(:twice)
    end

    # Il gate cross-batch usa la cache atomica (unless_exist), no-op sotto :null_store di test →
    # sostituiamo una cache reale fresca, come lo spec metrics del gate CYRA-48.
    describe "gate anti fan-out fra batch ravvicinati" do
      before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

      it "due batch error consecutivi sullo stesso progetto accodano UN solo alert entro la finestra" do
        expect do
          described_class.call(project: project, payload: payload("event_id" => SecureRandom.uuid, "level" => "error"))
          described_class.call(project: project, payload: payload("event_id" => SecureRandom.uuid, "level" => "error"))
        end.to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "log_alert", level: Logs::Entry.levels["error"])).exactly(:once)
      end
    end
  end
end
