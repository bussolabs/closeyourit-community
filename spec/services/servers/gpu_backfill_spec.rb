# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — lo spec vive accanto al servizio (prima stava fra quelli dei comandi di manutenzione,
# dove nessuno lo cercava rileggendo il servizio). Riempie l'uso della scheda grafica sui campioni
# già salvati: senza questo giro il grafico nasce con la storia amputata.
RSpec.describe Servers::GpuBackfill do
  let(:host) { create(:server_host) }

  def campione(payload:, gpu_pct: nil, recorded_at: 5.minutes.ago)
    create(:server_sample, host: host, gpu_pct: gpu_pct, recorded_at: recorded_at, payload: payload)
  end

  def una_scheda(uso: 42.0, watt: 90.5)
    { "gpu" => { "0" => { "n" => "GB10", "u" => uso, "p" => watt } } }
  end

  it "riempie uso e watt dai campioni che hanno il dettaglio nel payload" do
    riga = campione(payload: una_scheda)

    described_class.call

    expect(riga.reload.gpu_pct).to eq(42.0)
    expect(riga.gpu_watt).to eq(90.5)
  end

  it "non tocca i campioni senza scheda grafica" do
    riga = campione(payload: {})

    described_class.call

    expect(riga.reload.gpu_pct).to be_nil
  end

  it "non sovrascrive un valore già calcolato" do
    riga = campione(payload: una_scheda, gpu_pct: 7.0)

    described_class.call

    expect(riga.reload.gpu_pct).to eq(7.0)
  end

  it "dice quante righe ha aggiornato" do
    campione(payload: una_scheda)

    expect(described_class.call).to eq(1)
  end

  describe "più schede sulla stessa macchina" do
    # L'uso è quello della scheda più carica (una sola satura basta a spiegare un rallentamento),
    # mentre i watt sono il consumo di tutte insieme.
    it "prende l'uso più alto e la somma dei consumi" do
      riga = campione(payload: { "gpu" => { "0" => { "u" => 12.0, "p" => 30.0 },
                                            "1" => { "u" => 88.0, "p" => 45.5 } } })

      described_class.call

      expect(riga.reload.gpu_pct).to eq(88.0)
      expect(riga.gpu_watt).to eq(75.5)
    end
  end

  describe "payload incompleti" do
    it "scheda senza uso dichiarato → il campione resta scoperto" do
      riga = campione(payload: { "gpu" => { "0" => { "n" => "GB10", "p" => 90.5 } } })

      described_class.call

      expect(riga.reload.gpu_pct).to be_nil
    end

    it "uso presente ma consumo assente → riempie solo l'uso" do
      riga = campione(payload: { "gpu" => { "0" => { "u" => 42.0 } } })

      described_class.call

      expect(riga.reload.gpu_pct).to eq(42.0)
      expect(riga.gpu_watt).to be_nil
    end

    it "blocco della scheda di forma inattesa → nessuna eccezione, campione invariato" do
      riga = campione(payload: { "gpu" => "nessun dettaglio" })

      expect { described_class.call }.not_to raise_error
      expect(riga.reload.gpu_pct).to be_nil
    end
  end

  # A blocchi e non in un aggiornamento unico: la tabella ha un campione al minuto per macchina e un
  # solo comando terrebbe un lock lungo su una tabella che l'ingest sta scrivendo di continuo.
  it "lavora a blocchi: copre tutti i campioni anche con blocchi piccoli" do
    3.times { |i| campione(payload: una_scheda, recorded_at: i.minutes.ago) }

    expect(described_class.call(batch_size: 1)).to eq(3)
    expect(Servers::Sample.where(gpu_pct: nil).count).to eq(0)
  end

  it "rilanciato una seconda volta non riscrive niente" do
    campione(payload: una_scheda)
    described_class.call

    expect(described_class.call).to eq(0)
  end
end
