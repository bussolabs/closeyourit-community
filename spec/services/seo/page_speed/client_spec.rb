# frozen_string_literal: true

require "rails_helper"

# CYRA-539 — il client di PageSpeed Insights. Ogni ramo di errore ha una ragione diversa per chi
# legge la scheda del sito, e diventa una parola diversa sotto i numeri.
RSpec.describe Seo::PageSpeed::Client do
  let(:endpoint) { %r{pagespeedonline\.googleapis\.com/pagespeedonline/v5/runPagespeed} }
  let(:client) { described_class.new(api_key: "chiave-di-prova") }

  def fixture(nome) = Rails.root.join("spec/fixtures/seo/#{nome}.json").read

  # CYRA-546 — la chiave la porta l'organizzazione che sta usando la funzione, non l'installazione.
  describe ".for" do
    let(:organization) { create(:organization) }

    it "costruisce il client con la chiave di quell'organizzazione" do
      create(:integration_credential, :pagespeed, organization:, api_key: "chiave-della-organizzazione")
      stub_request(:get, endpoint).to_return(status: 200, body: fixture("pagespeed_success"))

      described_class.for(organization:).run(url: "https://acme.example", strategy: "mobile")

      expect(a_request(:get, endpoint).with { |req| req.uri.query.include?("key=chiave-della-organizzazione") })
        .to have_been_made
    end

    # Nil e non un'eccezione: «non collegato» non è un guasto, è una configurazione che manca, e chi
    # chiama deve poterlo dire a chi guarda invece di finire in un rescue insieme ai timeout.
    it "senza collegamento non c'è nessun client, e non è un guasto" do
      expect(described_class.for(organization:)).to be_nil
    end
  end

  # Il default da ENV è sparito di proposito: un default silenzioso rimetterebbe il consumo di tutte
  # le organizzazioni sulla chiave di chi gestisce l'installazione, senza che nessuno se ne accorga.
  describe "#initialize" do
    it "una chiave assente o vuota non costruisce niente" do
      expect { described_class.new(api_key: nil) }.to raise_error(KeyError)
      expect { described_class.new(api_key: "   ") }.to raise_error(KeyError)
      expect { described_class.new }.to raise_error(ArgumentError)
    end
  end

  describe "#run" do
    it "va all'endpoint di Google con la strategia chiesta" do
      stub_request(:get, endpoint).to_return(status: 200, body: fixture("pagespeed_success"))

      client.run(url: "https://acme.example", strategy: "mobile")

      expect(a_request(:get, endpoint).with { |req| req.uri.query.include?("strategy=mobile") })
        .to have_been_made
    end

    # `category` è un parametro RIPETIBILE, e le quattro categorie vanno chieste tutte: chiederne
    # una sola farebbe tornare tre punteggi vuoti, che si leggono come «il sito non è stato
    # misurato» invece che «non l'abbiamo chiesto».
    #
    # Il controllo è sulla query costruita e non sulla richiesta intercettata perché WebMock
    # NORMALIZZA l'URI e accorpa i parametri ripetuti, tenendo solo l'ultimo: da lì si vedrebbe un
    # `category=seo` solo, e il test passerebbe anche su un client rotto.
    it "chiede tutte e quattro le categorie, e la maschera dei campi" do
      query = client.send(:query_for, url: "https://acme.example", strategy: "mobile")

      Seo::PageSpeed::Constants::CATEGORIES.each do |category|
        expect(query).to include("category=#{CGI.escape(category)}")
      end
      expect(query).to include("fields=")
      expect(query).to include("locale=it")
    end

    it "restituisce la risposta già decodificata" do
      stub_request(:get, endpoint).to_return(status: 200, body: fixture("pagespeed_success"))

      expect(client.run(url: "https://acme.example", strategy: "mobile"))
        .to include("lighthouseResult")
    end

    # VERIFICATO CON UNA CHIAMATA VERA il 2026-08-15: senza chiave la quota giornaliera del consumer
    # anonimo è ZERO, non ridotta. La guida ufficiale dice ancora «can be used with or without an API
    # key»: in pratica è falso. Non si chiama affatto — un ripiego che a volte funziona è un guasto
    # intermittente travestito da funzionalità. Da CYRA-546 il client senza chiave non esiste
    # proprio: la costruzione fallisce prima, quindi nessuna chiamata anonima può partire.
    it "senza chiave non si arriva nemmeno a poter chiamare" do
      expect { described_class.new(api_key: nil) }.to raise_error(KeyError)
      expect(a_request(:get, endpoint)).not_to have_been_made
    end

    it "riconosce la quota esaurita dalla risposta vera di Google" do
      stub_request(:get, endpoint).to_return(status: 429, body: fixture("pagespeed_quota_exceeded"))

      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("quota_exceeded") }
    end

    it "distingue una chiave rifiutata da un guasto qualsiasi" do
      stub_request(:get, endpoint).to_return(status: 403, body: "{}")

      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("unauthorized") }
    end

    # Un 400 può voler dire due cose diverse per chi legge: l'indirizzo non va bene, oppure il
    # browser di Google non è riuscito a caricare la pagina. Sono due problemi di due persone diverse.
    it "distingue un indirizzo rifiutato da una pagina che Lighthouse non ha caricato" do
      stub_request(:get, endpoint)
        .to_return(status: 400, body: { error: { message: "Lighthouse returned error: ERRORED_DOCUMENT_REQUEST" } }.to_json)
      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("lighthouse_error") }

      stub_request(:get, endpoint).to_return(status: 400, body: { error: { message: "Invalid value" } }.to_json)
      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("invalid_url") }
    end

    it "un 500 di Google è un guasto a monte, non colpa del sito" do
      stub_request(:get, endpoint).to_return(status: 503, body: "")

      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("upstream_error") }
    end

    it "un timeout ha un nome suo: il giro non è fallito per colpa del sito" do
      stub_request(:get, endpoint).to_timeout

      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("timeout") }
    end

    it "una risposta che non è JSON non passa per buona" do
      stub_request(:get, endpoint).to_return(status: 200, body: "<html>oops</html>")

      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("unreadable") }
    end

    it "un 400 con un corpo illeggibile resta un indirizzo rifiutato, senza sollevare due volte" do
      stub_request(:get, endpoint).to_return(status: 400, body: "non json")

      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("invalid_url") }
    end

    it "una risposta JSON che non è un oggetto non passa per buona" do
      stub_request(:get, endpoint).to_return(status: 200, body: "[1, 2]")

      expect { client.run(url: "https://acme.example", strategy: "mobile") }
        .to raise_error(described_class::Error) { |e| expect(e.reason).to eq("unreadable") }
    end
  end
end
