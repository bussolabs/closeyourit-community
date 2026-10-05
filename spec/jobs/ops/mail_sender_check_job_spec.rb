# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ops::MailSenderCheckJob do
  def check_result(status, detail: nil)
    Ops::MailSenderCheck::Result.new(status: status, from: "CloseYourIt <noreply@notifications.example.test>",
                                     domain: "notifications.example.test", detail: detail)
  end

  before { allow(Rails.logger).to receive(:error) }
  before { allow(Rails.logger).to receive(:warn) }

  describe "#perform" do
    # DoD CYRA-233: se la configurazione di spedizione sparisce, qualcosa deve segnalarlo PRIMA che
    # serva mandare l'avviso vero. La traccia è nei log, non in un'email: il canale rotto non può
    # denunciarsi da solo.
    it "logga un ERROR quando il dominio del mittente non risulta configurato" do
      allow(Ops::MailSenderCheck).to receive(:call)
        .and_return(check_result(:unknown_domain, detail: "il dominio notifications.example.test non risulta"))

      described_class.perform_now

      expect(Rails.logger).to have_received(:error).with(a_string_including("nessuna email può partire"))
      expect(Rails.logger).to have_received(:error).with(a_string_including("notifications.example.test"))
    end

    it "logga un ERROR quando il dominio c'è ma non è verificato" do
      allow(Ops::MailSenderCheck).to receive(:call).and_return(check_result(:unverified, detail: "stato pending"))

      described_class.perform_now

      expect(Rails.logger).to have_received(:error).with(a_string_including("pending"))
    end

    # Senza chiave del fornitore l'app spegne l'invio: nessuna email parte nemmeno col DNS perfetto.
    # È il guasto gemello, ed era altrettanto muto.
    it "logga un ERROR quando manca la chiave del fornitore" do
      allow(Ops::MailSenderCheck).to receive(:call).and_return(check_result(:unconfigured, detail: "l'invio è spento"))

      described_class.perform_now

      expect(Rails.logger).to have_received(:error).with(a_string_including("Ops::MailSenderCheckJob"))
    end

    # Un fornitore che non risponde non prova che il mittente sia rotto: WARN, non ERROR. Alzare
    # l'allarme grosso per un guasto di rete è il modo più rapido per far ignorare gli allarmi veri.
    it "logga un WARN, non un ERROR, quando il fornitore non risponde" do
      allow(Ops::MailSenderCheck).to receive(:call).and_return(check_result(:error, detail: "Net::OpenTimeout"))

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(a_string_including("Net::OpenTimeout"))
      expect(Rails.logger).not_to have_received(:error)
    end

    # CYRA-771: la chiave di produzione è abilitata al solo invio, quindi l'elenco domini non le è
    # accessibile. Del mittente non sappiamo niente — WARN come per il fornitore muto, mai ERROR: le
    # email partono, e un ERROR quotidiano su un guasto inesistente svaluta tutti gli altri.
    it "logga un WARN che nomina il rimedio quando la chiave non può leggere i domini" do
      allow(Ops::MailSenderCheck).to receive(:call)
        .and_return(check_result(:restricted_key, detail: "la chiave del fornitore è abilitata al solo invio"))

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(a_string_including("solo invio"))
      expect(Rails.logger).to have_received(:warn).with(a_string_including("permesso di lettura"))
      expect(Rails.logger).not_to have_received(:error)
    end

    # Dalla chiave ristretta NON si deduce che il dominio del mittente sia verificato: il fornitore
    # tiene separate le due cose. La riga dice quello che sappiamo — cioè di non sapere.
    it "non promette che le email partano quando lo stato del mittente è ignoto" do
      allow(Ops::MailSenderCheck).to receive(:call)
        .and_return(check_result(:restricted_key, detail: "abilitata al solo invio"))

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(a_string_including("ignoto"))
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including("le email partono"))
    end

    it "non logga nulla quando il mittente è verificato (nessun rumore in salute)" do
      allow(Ops::MailSenderCheck).to receive(:call).and_return(check_result(:verified))

      described_class.perform_now

      expect(Rails.logger).not_to have_received(:error)
      expect(Rails.logger).not_to have_received(:warn)
    end

    # Il giro è osservazione: un guasto del fornitore non deve far fallire e ritentare il controllo.
    it "non solleva quando il fornitore è irraggiungibile davvero" do
      allow(Resend).to receive(:api_key).and_return("re_test_key")
      stub_request(:get, "https://api.resend.com/domains").to_timeout

      expect { described_class.perform_now }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(a_string_including("Ops::MailSenderCheckJob"))
    end
  end

  it "gira sulla corsia :maintenance come gli altri controlli periodici" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
