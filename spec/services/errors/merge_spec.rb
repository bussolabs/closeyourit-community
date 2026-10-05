# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Merge do
  let(:project) { create(:project) }
  let(:primary) { create(:error_group, project:, events_count: 10, users_count: 2) }
  let(:source) { create(:error_group, project:, events_count: 5, users_count: 3) }

  def merge(sources)
    described_class.call(primary:, source_ids: Array(sources).map(&:id))
  end

  it "sposta le occorrenze sul primario" do
    create_list(:error_event, 2, group: source, project:)
    create(:error_event, group: primary, project:)

    merge(source)

    expect(primary.reload.events.count).to eq(3)
  end

  it "somma le occorrenze invece di ricontarle" do
    # events_count sopravvive alla potatura: un COUNT sulle righe rimaste direbbe meno del vero.
    merge(source)

    expect(primary.reload.events_count).to eq(15)
  end

  # users_count conta utenti DISTINTI: sommarlo conterebbe due volte chi ha incontrato entrambi gli
  # errori — probabile proprio nei gruppi che si fondono, che sono lo stesso guasto.
  it "sugli utenti tiene il massimo, non la somma" do
    merge(source)

    expect(primary.reload.users_count).to eq(3)
  end

  # CYRA-380: «ha ricevuto contesto utente» è un fatto storico monotòno — se lo era il primario o una
  # qualsiasi sorgente, il gruppo fuso resta «tracciato» (OR, non max di un conteggio azzerabile).
  it "resta «tracciato» se lo era una sorgente anche quando il primario non lo era" do
    primary.update!(user_context_seen: false)
    source.update!(user_context_seen: true)

    merge(source)

    expect(primary.reload.user_context_seen).to be(true)
  end

  it "non è «tracciato» se nessuno dei gruppi fusi lo era" do
    primary.update!(user_context_seen: false)
    source.update!(user_context_seen: false)

    merge(source)

    expect(primary.reload.user_context_seen).to be(false)
  end

  it "allarga la finestra temporale al più vecchio e al più recente" do
    primary.update!(first_seen_at: 2.days.ago, last_seen_at: 1.hour.ago)
    source.update!(first_seen_at: 5.days.ago, last_seen_at: 10.minutes.ago)

    merge(source)

    expect(primary.reload.first_seen_at).to be_within(1.second).of(5.days.ago)
    expect(primary.reload.last_seen_at).to be_within(1.second).of(10.minutes.ago)
  end

  it "cancella i gruppi assorbiti" do
    expect { merge(source) }.to change { Errors::Group.exists?(source.id) }.from(true).to(false)
  end

  it "fonde più gruppi in una volta" do
    altro = create(:error_group, project:, events_count: 7)

    expect(merge([ source, altro ])).to be_ok
    expect(primary.reload.events_count).to eq(22)
    expect(Errors::Group.where(id: [ source.id, altro.id ])).to be_empty
  end

  # IL punto che rende la fusione duratura. Il fingerprint è la chiave con cui l'ingest ritrova il
  # gruppo: senza ereditarlo, la prima occorrenza successiva ricreerebbe il gruppo appena fuso.
  describe "fingerprint assorbiti" do
    it "eredita il fingerprint dei gruppi fusi" do
      merge(source)

      expect(primary.reload.merged_fingerprints).to include(source.fingerprint)
    end

    it "eredita anche quelli che le sorgenti avevano già assorbito" do
      source.update!(merged_fingerprints: [ "vecchio-fingerprint" ])

      merge(source)

      expect(primary.reload.merged_fingerprints).to include("vecchio-fingerprint", source.fingerprint)
    end

    # La prova che la fusione TIENE. Il fingerprint sul gruppo è un digest calcolato dal payload,
    # quindi il gruppo sorgente viene allineato a quello che l'evento produrrà davvero.
    it "una nuova occorrenza del gruppo fuso finisce nel primario, non ricrea la riga" do
      payload = { "exception" => { "values" => [ { "type" => "Boom", "value" => "x" } ] } }
      source.update!(fingerprint: Errors::Fingerprint.call(payload:))
      merge(source)

      expect do
        Errors::Ingest::Record.call(project:, payload: payload.merge("event_id" => SecureRandom.hex(16)))
      end.not_to change(Errors::Group, :count)

      expect(primary.reload.events.count).to eq(1)
    end
  end

  # I log collegati a mano sono lavoro umano di correlazione: dependent: :destroy li butterebbe.
  describe "log collegati" do
    it "li sposta sul primario invece di cancellarli" do
      entry = create(:log_entry, project:)
      create(:log_link, linkable: source, log_entry: entry)

      merge(source)

      expect(primary.reload.log_links.map(&:log_entry_id)).to include(entry.id)
    end

    it "non fallisce se il primario ha già lo stesso log collegato" do
      entry = create(:log_entry, project:)
      create(:log_link, linkable: source, log_entry: entry)
      create(:log_link, linkable: primary, log_entry: entry)

      expect(merge(source)).to be_ok
      expect(primary.reload.log_links.count).to eq(1)
    end
  end

  describe "guardie" do
    it "rifiuta senza sorgenti" do
      result = described_class.call(primary:, source_ids: [])

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ERROR-003")
    end

    it "ignora il primario passato fra le sorgenti" do
      result = described_class.call(primary:, source_ids: [ primary.id ])

      expect(result).to be_err
      expect(Errors::Group.exists?(primary.id)).to be(true)
    end

    # Tutto-o-niente: fondere i validi e ignorare gli altri lascerebbe l'utente convinto di aver
    # unito tre gruppi quando ne ha uniti due, senza poter tornare indietro.
    it "con una lista MISTA non fonde niente" do
      estraneo = create(:error_group)
      create(:error_event, group: source, project:)

      result = described_class.call(primary:, source_ids: [ source.id, estraneo.id ])

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ERROR-004")
      expect(result.error.message).to include(estraneo.id)
      expect(Errors::Group.exists?(source.id)).to be(true)
      expect(source.reload.events.count).to eq(1)
      expect(primary.reload.events_count).to eq(10)
    end

    it "rifiuta un id inesistente senza toccare nulla" do
      result = described_class.call(primary:, source_ids: [ SecureRandom.uuid ])

      expect(result).to be_err
      expect(primary.reload.events_count).to eq(10)
    end

    # Un fallimento a metà strada non deve lasciare occorrenze orfane o contatori gonfiati.
    it "se la cancellazione fallisce, non resta nulla a metà" do
      create(:error_event, group: source, project:)
      allow(Errors::Group).to receive(:where).and_call_original
      allow(Errors::Group).to receive(:where).with(id: [ source.id ])
                                             .and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { described_class.call(primary:, source_ids: [ source.id ]) }
        .to raise_error(ActiveRecord::StatementInvalid)

      expect(primary.reload.events_count).to eq(10)
      expect(source.reload.events.count).to eq(1)
    end
  end
end
