# frozen_string_literal: true

require "rails_helper"

# CYRA-544 — la prova della chiave al salvataggio. Quattro esiti distinti, perché si risolvono in
# quattro modi diversi: la chiave sbagliata si ri-copia, il servizio spento si accende nella console
# del fornitore, il fornitore irraggiungibile si riprova, e il resto si guarda.
RSpec.describe Integrations::Verify do
  def google_error(reason)
    { error: { code: 400, status: "INVALID_ARGUMENT", message: "qualcosa",
               details: [ { "@type" => "type.googleapis.com/google.rpc.ErrorInfo", reason: reason } ] } }.to_json
  end

  # L'esito si legge dallo slug dentro l'AppError: è quello che finisce in colonna. La forma completa
  # dell'errore la fissa la spec del contratto qui sotto, così questa scorciatoia non la nasconde.
  def esito(provider:, api_key:)
    risultato = described_class.call(provider: provider, api_key: api_key)
    risultato.ok? ? :ok : risultato.error.details[:outcome]
  end

  # `Result.err` porta un AppError, non una stringa (`app/services/result.rb` lo dichiara). Una
  # stringa nuda farebbe esplodere con NoMethodError il primo controller che prova a renderizzarla.
  describe "il contratto dell'errore" do
    it "è un AppError con codice, stato e messaggio leggibile" do
      stub_request(:get, %r{pagespeedonline}).to_return(status: 400, body: google_error("API_KEY_INVALID"))

      errore = described_class.call(provider: "pagespeed", api_key: "sbagliata").error

      expect(errore).to be_a(AppError)
      expect(errore.code).to eq("R422-INTEGRATION-001")
      expect(errore.status).to eq(:unprocessable_content)
      expect(errore.message).to eq(I18n.t("integrations.errors.invalid_key"))
      expect(errore.details[:outcome]).to eq(described_class::INVALID_KEY)
    end

    # Non si confronta la mappa con un elenco copiato a mano — sarebbe circolare. Si controlla che
    # ogni riga rispetti il formato del registro (`app/errors/README.md`) e che il codice dichiari lo
    # STESSO stato dell'esito: `R504-...` con `:bad_gateway` sarebbe una riga che mente al lettore.
    it "il codice di ogni esito è ben formato e concorda col suo stato" do
      prefissi = { unprocessable_content: "R422", gateway_timeout: "R504", bad_gateway: "R502" }

      described_class::OUTCOMES.each do |esito, spec|
        expect(spec[:code]).to match(/\AR\d{3}-INTEGRATION-\d{3}\z/), "#{esito}: codice fuori formato"
        expect(spec[:code]).to start_with(prefissi.fetch(spec[:status])),
                               "#{esito}: il codice #{spec[:code]} non concorda con lo stato #{spec[:status]}"
      end
    end
  end

  # Gli esiti che non dipendono da quale servizio Google si stia provando: li produce `verify_google`,
  # ed erano scritti sotto la sonda Gemini finché ce n'erano due (CYRA-765). Restano qui, sulla sonda
  # rimasta, perché è il ramo che decide se una chiave è rotta o se è il fornitore ad avere un guasto
  # — e senza di loro nessuno ci passerebbe più.
  describe "gli esiti comuni a ogni servizio Google" do
    let(:endpoint) { %r{pagespeedonline\.googleapis\.com/pagespeedonline/v5/runPagespeed} }

    # «Chiave sbagliata» e «servizio non attivo» sembrano lo stesso guasto e non lo sono: la seconda
    # si risolve accendendo il servizio, non ricopiando la chiave.
    it "distingue il servizio non attivo dalla chiave sbagliata" do
      stub_request(:get, endpoint).to_return(status: 403, body: google_error("SERVICE_DISABLED"))

      expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::SERVICE_DISABLED)
    end

    # Terzo caso, terzo posto dove si risolve: la chiave è valida e il servizio è acceso, ma le
    # restrizioni che le abbiamo messo sopra non la lasciano passare. Dire «ricopiala» o «accendi il
    # servizio» manderebbe la persona a fare una cosa che non risolve.
    %w[API_KEY_SERVICE_BLOCKED API_KEY_HTTP_REFERRER_BLOCKED API_KEY_IP_ADDRESS_BLOCKED
       API_KEY_ANDROID_APP_BLOCKED API_KEY_IOS_APP_BLOCKED].each do |ragione|
      it "#{ragione} è una restrizione della chiave, non una chiave sbagliata né un servizio spento" do
        stub_request(:get, endpoint).to_return(status: 403, body: google_error(ragione))

        expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::KEY_RESTRICTED)
      end
    end

    it "un fornitore che non risponde non è una chiave sbagliata" do
      stub_request(:get, endpoint).to_timeout

      expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::UNREACHABLE)
    end

    it "un guasto a monte resta un guasto a monte" do
      stub_request(:get, endpoint).to_return(status: 503, body: "")

      expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::UPSTREAM_ERROR)
    end

    it "una risposta illeggibile non passa per buona" do
      stub_request(:get, endpoint).to_return(status: 503, body: "<html>oops</html>")

      expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::UPSTREAM_ERROR)
    end

    # JSON valido non vuol dire forma attesa. Su `null` o su un array `dig` solleverebbe, e la sonda
    # esploderebbe invece di dare un esito: un guasto del nostro codice al posto di un verdetto.
    [ "null", "[]", '"boom"', '{"error":"stringa"}' ].each do |corpo|
      it "una risposta JSON di forma inattesa (#{corpo}) resta un esito, non un'eccezione" do
        stub_request(:get, endpoint).to_return(status: 503, body: corpo)

        expect { described_class.call(provider: "pagespeed", api_key: "AIza-x") }.not_to raise_error
        expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::UPSTREAM_ERROR)
      end
    end

    # `reason` è una stringa nel contratto, ma il contratto lo scrive l'altro: su un valore numerico
    # o annidato `start_with?` solleverebbe, e la risposta storta del fornitore diventerebbe un
    # guasto nostro.
    it "una ragione che non è una stringa resta un esito, non un'eccezione" do
      corpo = { error: { code: 503, details: [ { reason: 42 }, { reason: { nested: true } } ] } }.to_json
      stub_request(:get, endpoint).to_return(status: 503, body: corpo)

      expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::UPSTREAM_ERROR)
    end

    # Una connessione che si chiude a metà lettura non è un difetto dell'applicazione: senza queste
    # nel paniere, un fornitore che tronca la risposta uscirebbe come 500 al salvataggio.
    [ EOFError, Net::HTTPBadResponse, Errno::ECONNRESET ].each do |guasto|
      it "una connessione interrotta (#{guasto}) è irraggiungibile, non un 500" do
        stub_request(:get, endpoint).to_raise(guasto)

        expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::UNREACHABLE)
      end
    end
  end

  describe "PageSpeed" do
    let(:endpoint) { %r{pagespeedonline\.googleapis\.com/pagespeedonline/v5/runPagespeed} }

    # La sonda manda un indirizzo volutamente sbagliato: il cancello delle chiavi sta PRIMA della
    # validazione della richiesta, quindi la chiave si fa vedere senza far girare un'analisi vera,
    # che costerebbe quaranta secondi a ogni salvataggio.
    it "una richiesta rifiutata per l'indirizzo significa che la chiave è passata" do
      stub_request(:get, endpoint).to_return(status: 400, body: google_error("INVALID_ARGUMENT"))

      expect(described_class.call(provider: "pagespeed", api_key: "AIza-buona")).to be_ok
    end

    it "riconosce comunque la chiave sbagliata" do
      stub_request(:get, endpoint).to_return(status: 400, body: google_error("API_KEY_INVALID"))

      expect(esito(provider: "pagespeed", api_key: "sbagliata")).to eq(described_class::INVALID_KEY)
    end

    # Qui sta il rischio vero di questo percorso: siccome il 400 è l'esito ATTESO, ogni problema della
    # chiave che Google non chiami esattamente API_KEY_INVALID passerebbe per «verificata». I nomi
    # sono più di uno e Google può aggiungerne: si riconosce il prefisso, non un elenco chiuso.
    %w[API_KEY_EXPIRED API_KEY_NOT_FOUND].each do |ragione|
      it "#{ragione} è un problema della chiave, non una chiave verificata" do
        stub_request(:get, endpoint).to_return(status: 400, body: google_error(ragione))

        expect(esito(provider: "pagespeed", api_key: "scaduta")).to eq(described_class::INVALID_KEY)
      end
    end

    it "e nemmeno una restrizione passa per chiave verificata" do
      stub_request(:get, endpoint).to_return(status: 400, body: google_error("API_KEY_IP_ADDRESS_BLOCKED"))

      expect(esito(provider: "pagespeed", api_key: "ristretta")).to eq(described_class::KEY_RESTRICTED)
    end

    it "non fa girare un'analisi vera: chiede un indirizzo che il servizio rifiuta di suo" do
      stub_request(:get, endpoint).to_return(status: 400, body: google_error("INVALID_ARGUMENT"))

      described_class.call(provider: "pagespeed", api_key: "AIza-x")

      expect(a_request(:get, endpoint).with { |req| req.uri.query.include?("url=not-a-url") })
        .to have_been_made
    end

    # Qui il 400 è l'esito atteso, quindi è l'unico posto dove un rifiuto vale «chiave buona». Ma
    # deve essere un rifiuto DI GOOGLE: un 400 di un proxy in mezzo non prova che la chiave sia mai
    # arrivata, e prenderlo per buono segnerebbe verificata una credenziale che non lo è.
    it "un 400 che non viene da Google non conta come chiave buona" do
      stub_request(:get, endpoint).to_return(status: 400, body: "<html>proxy aziendale</html>")

      expect(esito(provider: "pagespeed", api_key: "AIza-x")).to eq(described_class::UPSTREAM_ERROR)
    end

    # Google non manda SEMPRE la ragione strutturata: capita un errore col solo messaggio. Siccome
    # qui il rifiuto è l'esito atteso, senza rete quel caso passerebbe per «chiave verificata» — ed è
    # il modo più diretto di dire una bugia a chi ha appena incollato una chiave rotta.
    it "un rifiuto senza ragione strutturata che nomina la chiave non passa per verificata" do
      corpo = { error: { code: 400, status: "INVALID_ARGUMENT",
                         message: "API key not valid. Please pass a valid API key." } }.to_json
      stub_request(:get, endpoint).to_return(status: 400, body: corpo)

      expect(esito(provider: "pagespeed", api_key: "sbagliata")).to eq(described_class::INVALID_KEY)
    end

    # La rete tira in una sola direzione: un rifiuto che parla dell'indirizzo resta un sì.
    it "ma un rifiuto che parla dell'indirizzo resta una chiave buona" do
      corpo = { error: { code: 400, status: "INVALID_ARGUMENT",
                         message: "The url parameter is malformed." } }.to_json
      stub_request(:get, endpoint).to_return(status: 400, body: corpo)

      expect(described_class.call(provider: "pagespeed", api_key: "AIza-buona")).to be_ok
    end
  end

  # Qui si passa dal client VERO con le risposte HTTP stubbate, non da un doppio che solleva un errore
  # costruito a mano. Il difetto che questo blocco ora copre era esattamente quello: leggevo
  # `error.status` credendo fosse il codice HTTP, mentre il client ci mette il simbolo Rack
  # (`:bad_gateway` anche per un 401). Una chiave rifiutata usciva come «guasto del fornitore» — il
  # contrario di ciò che questo servizio esiste per dire — e il doppio, costruito con `status: 401`,
  # non poteva accorgersene perché quella forma il client non la produce mai.
  describe "i casi che non arrivano nemmeno al fornitore" do
    it "una chiave vuota non si prova: è già sbagliata" do
      expect(esito(provider: "pagespeed", api_key: "  ")).to eq(described_class::INVALID_KEY)
    end

    it "un servizio che non conosciamo non inventa un esito buono" do
      expect(esito(provider: "inventato", api_key: "x")).to eq(described_class::UPSTREAM_ERROR)
    end
  end
end
