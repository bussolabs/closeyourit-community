# frozen_string_literal: true

require "rails_helper"
require "fugit"
require "yaml"

# CYRA-549 — il controllo giornaliero delle chiavi collegate. Risponde al guasto tipico di questo
# prodotto: una funzione che dipende da un servizio esterno smette di funzionare e nessuno lo sa,
# perché la chiave era buona il giorno in cui è stata incollata e nessuno l'ha più provata.
RSpec.describe Integrations::VerifyJob, type: :job do
  let(:organization) { create(:organization) }

  def google_error(reason)
    { error: { code: 400, status: "INVALID_ARGUMENT", message: "qualcosa",
               details: [ { "@type" => "type.googleapis.com/google.rpc.ErrorInfo", reason: reason } ] } }.to_json
  end

  # Scenario 2 del ticket, per intero e senza scorciatoie: la chiave è collegata e verificata, nel
  # frattempo qualcuno l'ha revocata, e il giro giornaliero deve dirlo — col motivo.
  describe "una chiave revocata si vede il giorno dopo" do
    it "la segna non funzionante, col motivo" do
      credenziale = create(:integration_credential, :verified, organization:, provider: "pagespeed")
      stub_request(:get, %r{pagespeedonline}).to_return(status: 400, body: google_error("API_KEY_INVALID"))

      described_class.perform_now

      expect(credenziale.reload.verification_error).to eq(Integrations::Verify::INVALID_KEY)
      expect(credenziale).to be_broken
    end

    it "e ricorda quando l'ha provata, altrimenti non si sa se il dato è di oggi o di un mese fa" do
      credenziale = create(:integration_credential, :broken, organization:, provider: "pagespeed")
      stub_request(:get, %r{pagespeedonline}).to_return(status: 400, body: google_error("API_KEY_INVALID"))

      described_class.perform_now

      expect(credenziale.reload.verified_at).to be_within(1.minute).of(Time.current)
    end
  end

  describe "una chiave che risponde" do
    it "torna verificata, e l'errore vecchio sparisce" do
      credenziale = create(:integration_credential, :broken, organization:, provider: "pagespeed")
      stub_request(:get, %r{pagespeedonline}).to_return(status: 200, body: {}.to_json)

      described_class.perform_now

      expect(credenziale.reload.verification_error).to be_nil
      expect(credenziale).to be_verified
    end

    # Il giro tocca l'esito, mai la chiave: un salvataggio che toccasse `api_key` farebbe scattare la
    # regola «chiave nuova, verifica da rifare» e cancellerebbe l'esito appena scritto.
    it "non tocca la chiave collegata" do
      credenziale = create(:integration_credential, organization:, provider: "pagespeed", api_key: "AIza-sua")
      stub_request(:get, %r{pagespeedonline}).to_return(status: 200, body: {}.to_json)

      described_class.perform_now

      expect(credenziale.reload.api_key).to eq("AIza-sua")
      expect(credenziale).to be_verified
    end
  end

  # Il fornitore irraggiungibile non dice niente sulla chiave, ed è comodo far finta che l'ultima
  # prova non sia avvenuta. Non si fa: la colonna racconta com'è andata l'ULTIMA prova, e tenersi il
  # verde di ieri perché oggi non si è riusciti a chiedere è il modo in cui una pagina rassicura
  # mentendo. Lo slug distingue i casi, quindi chi legge sa se ricopiare la chiave o riprovare dopo.
  it "scrive anche l'esito che non dipende dalla chiave, invece di tenersi il verde di ieri" do
    credenziale = create(:integration_credential, :verified, organization:, provider: "pagespeed")
    stub_request(:get, %r{pagespeedonline}).to_timeout

    described_class.perform_now

    expect(credenziale.reload.verification_error).to eq(Integrations::Verify::UNREACHABLE)
  end

  describe "il giro passa da tutte" do
    it "prova ogni organizzazione che ha collegato quel servizio" do
      prima = create(:integration_credential, organization:, provider: "pagespeed")
      seconda = create(:integration_credential, organization: create(:organization), provider: "pagespeed")
      stub_request(:get, %r{pagespeedonline}).to_return(status: 200, body: {}.to_json)

      described_class.perform_now

      expect(prima.reload).to be_verified
      expect(seconda.reload).to be_verified
    end

    # Un guasto su una credenziale non deve rubare il controllo a tutte le altre: il giro è
    # giornaliero, e saltarlo vuol dire un giorno intero di chiavi non provate.
    it "una credenziale che esplode non ferma le altre" do
      rotta = create(:integration_credential, organization:, provider: "pagespeed")
      buona = create(:integration_credential, organization: create(:organization), provider: "pagespeed")
      stub_request(:get, %r{pagespeedonline}).to_return(status: 200, body: {}.to_json)
      allow(Integrations::Verify).to receive(:call).and_wrap_original do |original, **kwargs|
        raise "esplosione" if kwargs[:api_key] == rotta.api_key

        original.call(**kwargs)
      end

      expect { described_class.perform_now }.not_to raise_error
      expect(buona.reload).to be_verified
    end

    # Una riga rimasta di un servizio ritirato dal registro non si può provare: non esiste più una
    # sonda per quel fornitore. Marcarla «non funzionante» sarebbe una bugia — la chiave non c'entra.
    it "salta le credenziali di un servizio che il registro non conosce più" do
      credenziale = create(:integration_credential, organization:, provider: "pagespeed")
      Integrations::Credential.where(id: credenziale.id).update_all(provider: "servizio-ritirato")

      described_class.perform_now

      expect(WebMock).not_to have_requested(:get, /./)
      expect(credenziale.reload.verification_error).to be_nil
    end
  end

  # Il giro esiste solo se qualcuno lo lancia. Senza questa riga in `recurring.yml` il job resta un
  # file nel repository che non gira mai, e la promessa «entro il giorno dopo» non è mantenuta da
  # nessuno.
  describe "è appeso al giro giornaliero" do
    let(:voce) do
      YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")
          .values.find { |task| task["class"] == described_class.name }
    end

    it "compare fra i ricorrenti di produzione" do
      expect(voce).to be_present
    end

    it "gira una volta al giorno sulla corsia dei lavori lunghi" do
      expect(voce["queue"]).to eq("batch")
      expect(Fugit.parse(voce.fetch("schedule")).rough_frequency).to eq(1.day.to_i)
    end
  end
end
