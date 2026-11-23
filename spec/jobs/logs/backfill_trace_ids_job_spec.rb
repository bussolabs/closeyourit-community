# frozen_string_literal: true

require "rails_helper"

# CYRA-345: recupero del trace id sui log storici (privi del campo strutturato) riconoscendolo nel
# testo del messaggio, così la correlazione log↔errori vale anche per i log già in retention.
RSpec.describe Logs::BackfillTraceIdsJob do
  let(:project) { create(:project) }

  it "riconosce e popola il trace id dal messaggio, marcandolo come estratto" do
    entry = create(:log_entry, project:, trace_id: nil,
                               message: "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom")
    described_class.perform_now
    entry.reload
    expect(entry.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
    expect(entry.trace_id_extracted).to be(true)
  end

  it "riconosce anche il Job ID di ActiveJob" do
    entry = create(:log_entry, project:, trace_id: nil,
                               message: "Performing Job (Job ID: 0c4f2e10-aaaa-4bbb-8ccc-1234567890ab)")
    described_class.perform_now
    expect(entry.reload.trace_id).to eq("0c4f2e10-aaaa-4bbb-8ccc-1234567890ab")
  end

  it "non tocca un log che ha già un trace id strutturato" do
    entry = create(:log_entry, project:, trace_id: "structured",
                               message: "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom")
    described_class.perform_now
    entry.reload
    expect(entry.trace_id).to eq("structured")
    expect(entry.trace_id_extracted).to be(false)
  end

  it "lascia invariato un log senza identificativo riconoscibile" do
    entry = create(:log_entry, project:, trace_id: nil, message: "riga senza id")
    described_class.perform_now
    expect(entry.reload.trace_id).to be_nil
  end

  # CYRA-559: i log raccolti mentre il riconoscimento era rotto restano scollegati per sempre se
  # nessuno ripassa lo storico. Sono la maggioranza: il formato che sfuggiva è quello standard delle
  # eccezioni Rails.
  it "recupera il codice dai messaggi Rails con spazi e a capo prima del tag (CYRA-559)" do
    entry = create(:log_entry, project:, trace_id: nil,
                               message: "  \n[e146fed6-1a2b-4c3d-8e4f-556677889900] ActiveRecord::RecordNotFound")
    described_class.perform_now
    entry.reload
    expect(entry.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
    expect(entry.trace_id_extracted).to be(true)
  end

  # Il pre-filtro SQL è solo un modo per non istanziare l'intera tabella: il verdetto resta del
  # pattern Ruby. Se il filtro fosse più stretto del pattern, il backfill scarterebbe log che
  # l'ingest invece riconosce — divergenza silenziosa fra le due strade.
  it "recupera anche un 'job id:' scritto in minuscolo, come fa l'ingest" do
    entry = create(:log_entry, project:, trace_id: nil,
                               message: "performing job (job id: 0c4f2e10-aaaa-4bbb-8ccc-1234567890ab)")
    described_class.perform_now
    expect(entry.reload.trace_id).to eq("0c4f2e10-aaaa-4bbb-8ccc-1234567890ab")
  end

  it "è idempotente (un secondo passaggio non cambia nulla)" do
    entry = create(:log_entry, project:, trace_id: nil,
                               message: "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom")
    described_class.perform_now
    described_class.perform_now
    expect(entry.reload.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
  end

  # CYRA-1233: il giro notturno guarda solo i log arrivati negli ultimi due giorni. Un log vecchio
  # già esaminato senza esito non torna candidato ogni notte, e la durata non cresce con lo storico.
  describe "finestra del giro notturno" do
    let(:uuid) { "e146fed6-1a2b-4c3d-8e4f-556677889900" }

    # Lo spy si arma dopo la creazione dei log: conta solo le letture fatte dal job.
    def spy_recognition
      allow(Logs::Ingest::Normalize).to receive(:trace_id_from_message).and_call_original
    end

    it "non rilegge un log arrivato prima della finestra" do
      create(:log_entry, project:, trace_id: nil, message: "[senza id] riga vecchia", created_at: 3.days.ago)
      spy_recognition
      described_class.perform_now
      expect(Logs::Ingest::Normalize).not_to have_received(:trace_id_from_message)
    end

    it "fra molti log vecchi legge e collega solo quello recente" do
      old = Array.new(5) do
        create(:log_entry, project:, trace_id: nil, message: "[#{uuid}] vecchio", created_at: 1.month.ago)
      end
      fresh = create(:log_entry, project:, trace_id: nil, message: "[#{uuid}] nuovo", created_at: 1.hour.ago)
      spy_recognition
      described_class.perform_now
      expect(Logs::Ingest::Normalize).to have_received(:trace_id_from_message).once.with(fresh.message)
      expect(fresh.reload.trace_id).to eq(uuid)
      expect(old.map { |entry| entry.reload.trace_id }).to all(be_nil)
    end

    it "con una data di partenza ripassa e collega anche i log vecchi" do
      entry = create(:log_entry, project:, trace_id: nil, message: "[#{uuid}] vecchio", created_at: 1.month.ago)
      described_class.perform_now(since: 2.months.ago)
      entry.reload
      expect(entry.trace_id).to eq(uuid)
      expect(entry.trace_id_extracted).to be(true)
    end
  end

  # CYRA-559: lo storico si ripara da sé solo se il giro parte davvero. Finché il recupero dipendeva
  # da un comando lanciato a mano al deploy, un difetto del riconoscimento lasciava i log scollegati
  # per sempre. Qui si verifica il patto: la pianificazione esiste e punta a questa classe.
  describe "pianificazione ricorrente" do
    let(:schedule) { YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)["production"] }

    it "gira ogni giorno in produzione sulla corsia dei lavori lunghi" do
      entry = schedule.values.find { |task| task["class"] == described_class.name }
      expect(entry).to be_present
      expect(entry["queue"]).to eq("batch")
      expect(entry["schedule"]).to be_present
    end
  end
end
