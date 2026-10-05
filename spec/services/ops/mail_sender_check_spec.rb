# frozen_string_literal: true

require "rails_helper"

# CYRA-233: il mittente di TUTTE le email (avvisi, riepiloghi, inviti, reimpostazione password) stava su
# un dominio senza alcuna configurazione di spedizione. Nessuno se n'era accorto perché il guasto non
# lascia traccia dove si guarda. Questo controllo è l'occhio che mancava.
RSpec.describe Ops::MailSenderCheck, type: :service do
  # La chiave vera del vault non deve decidere il ramo atteso, e la risposta finta non deve dipendere
  # dall'ordine degli esempi: chiave nota per ogni esempio, valore originale ripristinato dopo.
  around do |example|
    original = Resend.api_key
    Resend.api_key = "re_test_key"
    example.run
    Resend.api_key = original
  end

  def stub_domains(*entries, status: 200)
    stub_request(:get, "https://api.resend.com/domains")
      .to_return(status: status, body: { data: entries }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "mittente spedibile" do
    it "verified quando il dominio del mittente è verificato presso il fornitore" do
      stub_domains({ id: "d1", name: "notifications.example.test", status: "verified" })

      result = described_class.call(from: "CloseYourIt <noreply@notifications.example.test>")

      expect(result.status).to eq(:verified)
      expect(result.deliverable?).to be(true)
      expect(result.domain).to eq("notifications.example.test")
    end

    # Il mittente di staging porta un commento RFC fra parentesi: se il parsing dell'indirizzo si
    # rompesse lì, il controllo darebbe :invalid su una configurazione perfettamente valida.
    it "legge il dominio anche da un mittente con commento fra parentesi (staging)" do
      stub_domains({ id: "d1", name: "notifications.example.test", status: "verified" })

      result = described_class.call(from: "CloseYourIt (staging) <noreply@notifications.example.test>")

      expect(result.status).to eq(:verified)
      expect(result.domain).to eq("notifications.example.test")
    end

    it "accetta anche un mittente senza nome visualizzato" do
      stub_domains({ id: "d1", name: "notifications.example.test", status: "verified" })

      expect(described_class.call(from: "noreply@notifications.example.test").status).to eq(:verified)
    end
  end

  describe "mittente non spedibile" do
    # Il guasto di CYRA-233 in una riga: il dominio del mittente non risulta proprio all'elenco.
    it "unknown_domain quando il dominio del mittente non è fra quelli configurati" do
      stub_domains({ id: "d1", name: "altro.example.test", status: "verified" })

      result = described_class.call(from: "CloseYourIt <noreply@notifications.example.test>")

      expect(result.status).to eq(:unknown_domain)
      expect(result.deliverable?).to be(false)
      expect(result.detail).to include("notifications.example.test")
      # Qui il fornitore ha risposto: il mittente NON spedisce. Non è un «non lo so» (CYRA-771).
      expect(result.unverifiable?).to be(false)
    end

    # Un dominio aggiunto ma con i record DNS non ancora propagati non spedisce: vale come guasto.
    it "unverified quando il dominio c'è ma non è verificato" do
      stub_domains({ id: "d1", name: "notifications.example.test", status: "pending" })

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.status).to eq(:unverified)
      expect(result.deliverable?).to be(false)
      expect(result.detail).to include("pending")
    end

    # Il match è ESATTO: Resend spedisce dal dominio registrato, non dai suoi sottodomini. Accettare il
    # padre darebbe un verde falso — lo stesso silenzio che ha lasciato passare CYRA-233.
    it "unknown_domain quando è verificato soltanto il dominio padre" do
      stub_domains({ id: "d1", name: "example.test", status: "verified" })

      expect(described_class.call(from: "noreply@notifications.example.test").status).to eq(:unknown_domain)
    end
  end

  describe "configurazione assente o malformata" do
    # Senza chiave, in produzione l'app spegne l'invio (config/environments/production.rb): non parte
    # una mail nemmeno col DNS perfetto. È un guasto quanto il dominio morto, e va detto.
    it "unconfigured senza chiave del fornitore, senza fare alcuna richiesta" do
      Resend.api_key = nil

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.status).to eq(:unconfigured)
      expect(result.deliverable?).to be(false)
      expect(WebMock).not_to have_requested(:get, /api\.resend\.com/)
    end

    it "invalid_sender quando il mittente configurato non è un indirizzo" do
      result = described_class.call(from: "CloseYourIt")

      expect(result.status).to eq(:invalid_sender)
      expect(WebMock).not_to have_requested(:get, /api\.resend\.com/)
    end

    it "invalid_sender quando il mittente è vuoto" do
      expect(described_class.call(from: "  ").status).to eq(:invalid_sender)
    end
  end

  # CYRA-771: in produzione la card della posta era ROSSA mentre le email partivano. La chiave usata
  # per spedire è ristretta al solo invio, quindi il fornitore RIFIUTA la lettura dell'elenco domini:
  # il rifiuto finiva nel rescue generico, diventava :error e la pagina di salute lo dipingeva come
  # «mittente rotto». Un allarme che grida al lupo insegna a ignorare quelli veri.
  describe "chiave ristretta al solo invio" do
    def stub_restricted_key
      stub_request(:get, "https://api.resend.com/domains")
        .to_return(status: 401,
                   body: { statusCode: 401, name: "restricted_api_key",
                           message: "This API key is restricted to only send emails" }.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "restricted_key, non error, quando il fornitore rifiuta la lettura dei domini" do
      stub_restricted_key

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.status).to eq(:restricted_key)
      expect(result.detail).to include("solo invio")
    end

    # Il cuore del ticket: «non posso controllare» NON è «non spedisce». Il mittente resta ignoto,
    # e chi legge il risultato deve poter distinguere le due cose senza guardare il testo del dettaglio.
    it "non è spedibile ma è dichiarato non verificabile" do
      stub_restricted_key

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.deliverable?).to be(false)
      expect(result.unverifiable?).to be(true)
    end

    it "non solleva e non lascia trapelare la chiave" do
      stub_restricted_key

      result = nil
      expect { result = described_class.call(from: "noreply@notifications.example.test") }.not_to raise_error
      expect(result.to_h.values.join).not_to include("re_test_key")
    end
  end

  describe "fornitore non raggiungibile" do
    # Il controllo osserva, non rompe: un guasto dell'API non deve sollevare (il chiamante è un job
    # ricorrente, e un raise lo farebbe ritentare a vuoto).
    it "error senza sollevare quando l'API risponde male" do
      stub_request(:get, "https://api.resend.com/domains")
        .to_return(status: 401, body: { statusCode: 401, message: "API key is invalid" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = nil
      expect { result = described_class.call(from: "noreply@notifications.example.test") }.not_to raise_error
      expect(result.status).to eq(:error)
      expect(result.deliverable?).to be(false)
      # NON è un «non posso controllare» (CYRA-771): in :error ci finisce anche la chiave revocata,
      # che è la stessa che spedisce — lì la posta è giù per davvero e il rosso va tenuto.
      expect(result.unverifiable?).to be(false)
    end

    it "error senza sollevare quando l'API non risponde affatto" do
      stub_request(:get, "https://api.resend.com/domains").to_timeout

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.status).to eq(:error)
      expect(result.detail).to be_present
    end

    # Il dettaglio finisce nei log e nella pagina di salute: la chiave non ci deve mai comparire.
    it "non espone mai la chiave del fornitore nel risultato" do
      stub_request(:get, "https://api.resend.com/domains").to_timeout

      result = described_class.call(from: "noreply@notifications.example.test")

      expect(result.to_h.values.join).not_to include("re_test_key")
    end
  end

  describe "mittente di default" do
    # Nessun argomento = il mittente che useranno davvero le email: MAIL_FROM se c'è, altrimenti il
    # default di ApplicationMailer. Se questi due divergessero, il controllo guarderebbe un altro posto.
    it "senza argomenti controlla il mittente di ApplicationMailer" do
      stub_domains({ id: "d1", name: Mail::Address.new(ApplicationMailer.default[:from]).domain,
                     status: "verified" })

      expect(described_class.call.status).to eq(:verified)
    end
  end
end
