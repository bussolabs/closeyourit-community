# frozen_string_literal: true

require "rails_helper"

# CYRA-754 · La prova che il database primary risponde davvero, non che il processo sia su.
RSpec.describe Ops::DatabaseHealth do
  describe ".call" do
    it "dice disponibile quando il primary risponde alla domanda di prova" do
      result = described_class.call

      expect(result).to be_available
      expect(result.error).to be_nil
    end

    it "interroga il PRIMARY, non una connessione qualunque" do
      allow(ApplicationRecord).to receive(:connection).and_call_original

      described_class.call

      expect(ApplicationRecord).to have_received(:connection)
    end

    context "quando il database non risponde" do
      before do
        connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
        allow(ApplicationRecord).to receive(:connection).and_return(connection)
        allow(connection).to receive(:select_value)
          .and_raise(ActiveRecord::ConnectionNotEstablished, "connessione rifiutata su 10.0.0.9:5432")
      end

      it "risponde non disponibile invece di sollevare" do
        expect { described_class.call }.not_to raise_error
        expect(described_class.call).not_to be_available
      end

      # L'endpoint che lo espone è pubblico e senza auth: fuori esce il TIPO di guasto, mai il
      # messaggio del driver — quello nomina host, porta e nome del database.
      it "riporta il tipo di guasto, non il messaggio del driver" do
        result = described_class.call

        expect(result.error).to eq("ActiveRecord::ConnectionNotEstablished")
        expect(result.error).not_to include("10.0.0.9")
      end

      it "lascia il dettaglio nei log, dove serve a chi ripara" do
        allow(Rails.logger).to receive(:error)

        described_class.call

        expect(Rails.logger).to have_received(:error).with(/connessione rifiutata su 10\.0\.0\.9:5432/)
      end
    end

    # Un guasto di rete non arriva sempre come errore di ActiveRecord: il driver può sollevare
    # qualunque cosa, e un health check che esplode è un 500 al posto di un 503 — chi lo interroga
    # non distingue "database giù" da "endpoint rotto".
    it "regge anche un guasto che non è un errore di ActiveRecord" do
      connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
      allow(ApplicationRecord).to receive(:connection).and_return(connection)
      allow(connection).to receive(:select_value).and_raise(IOError, "connessione chiusa")

      result = described_class.call

      expect(result).not_to be_available
      expect(result.error).to eq("IOError")
    end
  end
end
