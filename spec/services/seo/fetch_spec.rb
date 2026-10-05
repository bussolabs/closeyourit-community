# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Fetch, type: :service do
  # Gli host di test non risolvono via DNS in CI → stub su un IP pubblico, altrimenti ogni fetch
  # verrebbe scambiato per un tentativo verso la rete interna.
  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  it "scarica la pagina e riporta stato, corpo e tempo di risposta" do
    stub_request(:get, "https://sito.test/").to_return(status: 200, body: "<html></html>",
                                                       headers: { "Content-Type" => "text/html" })

    result = described_class.call(url: "https://sito.test/")

    expect(result).to be_ok
    expect(result).to be_html
    expect(result.status_code).to eq(200)
    expect(result.body).to include("<html>")
    expect(result.response_time_ms).to be_a(Integer).and be >= 0
  end

  it "si presenta con un user-agent che dice chi siamo" do
    stub = stub_request(:get, "https://sito.test/")
           .with(headers: { "User-Agent" => described_class::USER_AGENT })
           .to_return(status: 200, body: "ok")

    described_class.call(url: "https://sito.test/")

    expect(stub).to have_been_requested
  end

  describe "difesa dagli indirizzi interni" do
    it "non apre nemmeno la connessione verso un host che risolve dentro casa" do
      allow(NetworkGuard).to receive(:resolve).and_return([ "10.0.0.9" ])
      stub = stub_request(:get, "https://interno.test/")

      result = described_class.call(url: "https://interno.test/")

      expect(result).to be_blocked
      expect(stub).not_to have_been_requested
    end

    it "rivaluta ogni salto della catena: un redirect verso l'interno viene fermato" do
      allow(NetworkGuard).to receive(:resolve).with("sito.test").and_return([ "93.184.216.34" ])
      allow(NetworkGuard).to receive(:resolve).with("169.254.169.254").and_return([ "169.254.169.254" ])
      stub_request(:get, "https://sito.test/").to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest/meta-data" })
      metadata = stub_request(:get, "http://169.254.169.254/latest/meta-data")

      result = described_class.call(url: "https://sito.test/")

      expect(result).to be_blocked
      expect(metadata).not_to have_been_requested
    end

    it "rifiuta schemi che non siano http o https" do
      expect(described_class.call(url: "file:///etc/passwd").error).to eq("invalid_url")
      expect(described_class.call(url: "non-una-url").error).to eq("invalid_url")
    end
  end

  describe "redirect" do
    it "segue la catena e la conserva" do
      stub_request(:get, "https://sito.test/vecchia").to_return(status: 301, headers: { "Location" => "/nuova" })
      stub_request(:get, "https://sito.test/nuova").to_return(status: 200, body: "ok",
                                                              headers: { "Content-Type" => "text/html" })

      result = described_class.call(url: "https://sito.test/vecchia")

      expect(result).to be_ok
      expect(result).to be_redirected
      expect(result.redirect_chain).to eq([ "https://sito.test/vecchia" ])
      expect(result.final_url).to eq("https://sito.test/nuova")
    end

    it "si ferma quando i salti sono troppi invece di girare all'infinito" do
      stub_request(:get, %r{https://sito\.test/anello}).to_return(status: 302, headers: { "Location" => "/anello" })

      result = described_class.call(url: "https://sito.test/anello")

      expect(result.error).to eq("too_many_redirects")
    end
  end

  it "tronca i corpi enormi invece di portarsi in memoria un file intero" do
    stub_request(:get, "https://sito.test/gigante")
      .to_return(status: 200, body: "a" * (described_class::MAX_BODY_BYTES + 1_000),
                 headers: { "Content-Type" => "text/html" })

    result = described_class.call(url: "https://sito.test/gigante")

    expect(result.body.bytesize).to eq(described_class::MAX_BODY_BYTES)
    expect(result).to be_truncated
  end

  it "una pagina dentro il tetto non risulta tagliata" do
    stub_request(:get, "https://sito.test/").to_return(status: 200, body: "<html></html>",
                                                       headers: { "Content-Type" => "text/html" })

    expect(described_class.call(url: "https://sito.test/")).not_to be_truncated
  end

  # CYRA-807 — Qui non si guarda la lunghezza di quel che torna, ma quanto si è letto: con lo stub
  # le due cose coincidono sempre, quindi serve un server vero. La risposta promette molto più di
  # quanto manda e poi tace: chi legge fino in fondo aspetta invano e scade.
  describe "il tetto si applica DURANTE la lettura, non dopo" do
    let(:testa) { "a" * (described_class::MAX_BODY_BYTES + 64_000) }
    let(:responses) { [ pagina_promessa_enorme(testa) ] }
    let(:server) { StreamingBodyServer.new(responses).start }
    let(:url) { "http://127.0.0.1:#{server.port}/gigante" }

    # WebMock va tolto di mezzo, non solo autorizzato: il suo `Net::HTTP#request` inoltra la
    # richiesta vera SENZA il blocco (`super(request, nil, &nil)`) e chiama il nostro solo DOPO aver
    # letto tutto il corpo. Con lui in mezzo, qualunque prova di lettura a pezzi misurerebbe il suo
    # comportamento invece del nostro. Si parla solo con il server sul loopback qui sotto.
    around do |example|
      WebMock.disable!
      example.run
    ensure
      WebMock.enable!
    end

    before { allow(NetworkGuard).to receive(:resolved_public_address).and_return("127.0.0.1") }
    after { server.stop }

    # Content-Length dichiara 64 MB, il server ne manda poco più del tetto: il resto non arriverà mai.
    def pagina_promessa_enorme(body, headers: {})
      { headers: { "Content-Type" => "text/html" }.merge(headers), body: body,
        declared_length: 64_000_000 }
    end

    # ~32 MB di corpo in ~32 KB di rete: il tetto va speso sui byte decompressi, o una risposta
    # compressa lo aggirerebbe di mille volte.
    def gzip_di(bytes)
      buffer = StringIO.new(String.new(encoding: Encoding::BINARY))
      writer = Zlib::GzipWriter.new(buffer)
      pezzo = "a" * 64_000
      (bytes / pezzo.bytesize).times { writer.write(pezzo) }
      writer.close
      buffer.string
    end

    it "si ferma al tetto invece di aspettare il resto della risposta" do
      result = described_class.call(url: url, timeout: 1)

      expect(result.error).to be_nil
      expect(result.body.bytesize).to eq(described_class::MAX_BODY_BYTES)
      expect(result).to be_truncated
    end

    it "libera la connessione invece di lasciarla appesa a metà scaricamento" do
      result = described_class.call(url: url, timeout: 1)

      expect(result.error).to be_nil # e non "timeout": ha chiuso perché aveva finito, non perché ha rinunciato
      expect(server.client_closed_early?).to be(true)
    end

    context "quando il corpo finisce esattamente sul tetto" do
      let(:testa) { "a" * described_class::MAX_BODY_BYTES }

      it "smette lo stesso, invece di aspettare un pezzo che non arriverà" do
        result = described_class.call(url: url, timeout: 1)

        expect(result.error).to be_nil # fermarsi solo SOPRA il tetto qui costerebbe il timeout
        expect(result.body.bytesize).to eq(described_class::MAX_BODY_BYTES)
      end
    end

    context "quando la risposta è compressa" do
      let(:responses) do
        [ pagina_promessa_enorme(gzip_di(32_000_000), headers: { "Content-Encoding" => "gzip" }) ]
      end

      it "il tetto vale sui byte decompressi" do
        result = described_class.call(url: url, timeout: 1)

        expect(result.error).to be_nil
        expect(result.body.bytesize).to eq(described_class::MAX_BODY_BYTES)
        expect(result).to be_truncated
      end
    end

    context "quando la pagina enorme sta dietro un reindirizzamento" do
      let(:responses) do
        [ { status: "302 Found", headers: { "Location" => "/gigante" }, body: "" },
          pagina_promessa_enorme(testa) ]
      end

      it "il tetto vale anche dopo il salto" do
        result = described_class.call(url: "http://127.0.0.1:#{server.port}/vecchia", timeout: 1)

        expect(result.error).to be_nil
        expect(result).to be_redirected
        expect(result.body.bytesize).to eq(described_class::MAX_BODY_BYTES)
        expect(result).to be_truncated
      end
    end

    context "quando è il reindirizzamento stesso a promettere un corpo enorme" do
      let(:responses) do
        [ { status: "302 Found", headers: { "Location" => "/arrivo" }, body: "vai di là",
            declared_length: 64_000_000 },
          { headers: { "Content-Type" => "text/html" }, body: "<html>arrivato</html>" } ]
      end

      it "non lo scarica affatto: di un salto interessa solo dove porta" do
        result = described_class.call(url: "http://127.0.0.1:#{server.port}/vecchia", timeout: 1)

        expect(result.error).to be_nil
        expect(result.body).to include("arrivato")
      end
    end
  end

  it "un timeout è un esito, non un'eccezione che risale" do
    stub_request(:get, "https://sito.test/lenta").to_timeout

    expect(described_class.call(url: "https://sito.test/lenta").error).to eq("timeout")
  end

  it "una connessione rifiutata resta un esito" do
    stub_request(:get, "https://sito.test/giu").to_raise(Errno::ECONNREFUSED)

    expect(described_class.call(url: "https://sito.test/giu").error).to be_present
  end
end
