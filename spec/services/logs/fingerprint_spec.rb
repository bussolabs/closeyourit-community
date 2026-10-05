# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — l'impronta che rende «lo stesso messaggio» due righe che differiscono solo per i numeri
# (CYRA-348). Regole poche e dichiarate, non somiglianza: meglio due gruppi che uno sbagliato, perché
# un gruppo che mescola guasti diversi nasconde proprio quello che si sta cercando.
RSpec.describe Logs::Fingerprint, type: :service do
  def fp(message, level: nil) = described_class.call(message: message, level: level)

  describe "forma dell'impronta" do
    it "è una stringa di 64 caratteri esadecimali" do
      expect(fp("qualcosa è successo")).to match(/\A[0-9a-f]{64}\z/)
    end

    it "lo stesso messaggio dà sempre la stessa impronta" do
      expect(fp("qualcosa è successo")).to eq(fp("qualcosa è successo"))
    end

    it "messaggi diversi danno impronte diverse" do
      expect(fp("primo guasto")).not_to eq(fp("secondo guasto"))
    end
  end

  describe "parti variabili che NON devono separare due righe" do
    it "identificatori numerici" do
      expect(fp("utente 42 non trovato")).to eq(fp("utente 99999 non trovato"))
    end

    it "numeri con la virgola o il punto" do
      expect(fp("saldo 12,50 negativo")).to eq(fp("saldo 3.10 negativo"))
    end

    it "codici identificativi lunghi" do
      expect(fp("richiesta 3f2504e0-4f89-11d3-9a0c-0305e82c3301 fallita"))
        .to eq(fp("richiesta 550e8400-e29b-41d4-a716-446655440000 fallita"))
    end

    # CYRA-730: il testo arriva ai pattern già in minuscolo, quindi la `T` del formato standard va
    # riconosciuta anche minuscola. Prima non lo era e ogni riga con l'orario faceva gruppo a sé.
    it "orari nel formato standard, con la T fra data e ora" do
      expect(fp("chiuso il 2026-01-01T10:00:00Z")).to eq(fp("chiuso il 2026-09-02T23:31:00Z"))
    end

    it "orari col separatore spazio" do
      expect(fp("chiuso il 2026-01-01 10:00:00")).to eq(fp("chiuso il 2026-09-02 23:31:00"))
    end

    it "orari con i decimi e il fuso dichiarato" do
      expect(fp("chiuso il 2026-01-01T10:00:00.123+02:00")).to eq(fp("chiuso il 2026-09-02T23:31:00.999+02:00"))
    end

    it "date senza orario" do
      expect(fp("scadenza 2026-01-01")).to eq(fp("scadenza 2027-12-31"))
    end

    it "impronte esadecimali lunghe" do
      expect(fp("commit #{'a' * 40} rifiutato")).to eq(fp("commit #{'b' * 40} rifiutato"))
    end

    it "tempi e dimensioni con unità di misura" do
      expect(fp("risposta in 120ms")).to eq(fp("risposta in 4300ms"))
      expect(fp("caricato 12mb")).to eq(fp("caricato 250mb"))
    end

    it "maiuscole, minuscole e spazi in eccesso" do
      expect(fp("  Timeout   Della   Richiesta ")).to eq(fp("timeout della richiesta"))
    end
  end

  describe "differenze che DEVONO separare due righe" do
    it "il livello: lo stesso testo come avviso e come errore sono due cose diverse" do
      expect(fp("disco quasi pieno", level: "warn")).not_to eq(fp("disco quasi pieno", level: "error"))
    end

    it "il livello assente non equivale a un livello dichiarato" do
      expect(fp("disco quasi pieno")).not_to eq(fp("disco quasi pieno", level: "error"))
    end

    it "parole diverse, anche a parità di numeri" do
      expect(fp("utente 42 non trovato")).not_to eq(fp("ordine 42 non trovato"))
    end
  end

  describe "ordine delle regole" do
    # I codici identificativi e le date si riconoscono prima dei numeri nudi: al contrario un uuid
    # verrebbe spezzato pezzo per pezzo e due righe identiche finirebbero in gruppi diversi.
    it "un codice identificativo resta un pezzo solo, non una fila di numeri" do
      a = fp("id 3f2504e0-4f89-11d3-9a0c-0305e82c3301")
      b = fp("id 00000000-0000-0000-0000-000000000000")
      expect(a).to eq(b)
    end
  end

  describe "casi limite" do
    it "messaggio assente → impronta calcolabile lo stesso" do
      expect(fp(nil)).to match(/\A[0-9a-f]{64}\z/)
    end

    it "messaggio vuoto e messaggio di soli spazi sono la stessa cosa" do
      expect(fp("")).to eq(fp("   "))
    end
  end
end
