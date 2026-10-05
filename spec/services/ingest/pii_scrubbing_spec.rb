# frozen_string_literal: true

require "rails_helper"

# CYRA-735 — la rimozione dei dati personali dal dato in ingresso vive qui, in un punto solo, e i tre
# canali che portano testo scritto dalle persone (errori, log, campioni dei server) la applicano tutti.
# Prima esisteva compiuta solo nel canale errori: il canale log redigeva le sole chiavi sensibili dei
# dati strutturati e lasciava intatto il testo del messaggio, e il canale server — che trasporta i log
# di sistema della macchina, la sorgente più libera di tutte — non redigeva niente.
#
# Denylist canonica condivisa con gli SDK: closeyourit-docs/decisions/2026-07-09-pii-scrub-parity.md.
RSpec.describe Ingest::PiiScrubbing, type: :service do
  # Un mixin si prova sul suo contratto, non attraverso le classi che lo includono.
  let(:scrubber) { Class.new { include Ingest::PiiScrubbing }.new }

  describe "#scrub_value" do
    it "redige il valore di una chiave sensibile e lascia il resto intatto" do
      expect(scrubber.scrub_value("password" => "hunter2", "area" => "checkout"))
        .to eq("password" => "[FILTERED]", "area" => "checkout")
    end

    it "scende dentro hash annidati e liste di hash" do
      sporco = { "users" => [ { "token" => "t", "id" => 1 } ], "meta" => { "api_key" => "k" } }

      expect(scrubber.scrub_value(sporco))
        .to eq("users" => [ { "token" => "[FILTERED]", "id" => 1 } ], "meta" => { "api_key" => "[FILTERED]" })
    end

    it "strippa la query dai valori che sono un indirizzo di pagina (può portare token ed email)" do
      expect(scrubber.scrub_value("url" => "https://x.test/pay?token=SECRET"))
        .to eq("url" => "https://x.test/pay")
    end

    it "conserva le chiavi: si redige il valore, non il nome del campo" do
      expect(scrubber.scrub_value("email" => "a@b.test").keys).to eq(%w[email])
    end

    it "lascia com'è ciò che non è una struttura (numeri, booleani, nil, testo libero)" do
      expect(scrubber.scrub_value(42)).to eq(42)
      expect(scrubber.scrub_value(nil)).to be_nil
      expect(scrubber.scrub_value("testo qualunque")).to eq("testo qualunque")
    end

    it "non modifica l'oggetto ricevuto: torna una copia redatta" do
      originale = { "password" => "hunter2" }
      scrubber.scrub_value(originale)

      expect(originale["password"]).to eq("hunter2")
    end
  end

  describe "#scrub_message (testo libero)" do
    it "redige i valori sensibili scritti come chiave=valore dentro una frase" do
      expect(scrubber.scrub_message("GET /pay?token=SECRET&plan=pro"))
        .to eq("GET /pay?token=[FILTERED]&plan=pro")
    end

    it "lascia intatto tutto il resto del testo: non è una censura, è una redazione mirata" do
      expect(scrubber.scrub_message("connessione rifiutata su porta 5432"))
        .to eq("connessione rifiutata su porta 5432")
    end

    it "non svuota mai un messaggio: al posto del valore resta il segnaposto" do
      expect(scrubber.scrub_message("password=hunter2")).to eq("password=[FILTERED]")
    end

    # Il valore di un indirizzo non è sensibile, ma la sua query sì: se il primo pezzo si mangia
    # anche il resto, il token dentro la query esce in chiaro.
    it "redige il parametro sensibile dentro un indirizzo assegnato a una chiave innocua" do
      expect(scrubber.scrub_message("url=https://x.test/a?token=SECRET"))
        .to eq("url=https://x.test/a?token=[FILTERED]")
    end

    it "un valore che contiene il segno di uguale viene redatto per intero" do
      expect(scrubber.scrub_message("token=YWJjZA==")).to eq("token=[FILTERED]")
    end
  end

  # Le altre tre forme in cui un dato personale finisce dentro un testo libero: l'intestazione
  # scritta col due punti, il dato strutturato citato fra virgolette, l'indirizzo email nudo.
  describe "#scrub_message: le forme diverse da chiave=valore" do
    it "redige il valore di un'intestazione di autenticazione fino a fine riga" do
      expect(scrubber.scrub_message("Authorization: Bearer SECRET"))
        .to eq("Authorization: [FILTERED]")
    end

    it "redige un cookie intero, non il primo pezzo (le coppie sono separate da punto e virgola)" do
      expect(scrubber.scrub_message("Cookie: a=1; sid=SECRET")).to eq("Cookie: [FILTERED]")
    end

    it "l'intestazione redatta non si porta via le righe successive" do
      expect(scrubber.scrub_message("Authorization: Bearer SECRET\nGET /ok"))
        .to eq("Authorization: [FILTERED]\nGET /ok")
    end

    it "redige il valore citato di una chiave sensibile in un dato strutturato" do
      expect(scrubber.scrub_message('{"password":"hunter2","user":"mario"}'))
        .to eq('{"password":"[FILTERED]","user":"mario"}')
    end

    it "redige un indirizzo email scritto per intero nel testo" do
      expect(scrubber.scrub_message("invio la ricevuta a mario.rossi+ordini@example.co.uk"))
        .to eq("invio la ricevuta a [FILTERED]")
    end

    # Nei log di sistema il nome di un servizio a istanze ha la stessa forma di un indirizzo email:
    # redigerlo renderebbe illeggibile proprio la sorgente che questo ticket voleva coprire.
    it "NON tocca i nomi dei servizi di sistema a istanze, che somigliano a un indirizzo email" do
      expect(scrubber.scrub_message("getty@tty1.service failed")).to eq("getty@tty1.service failed")
      expect(scrubber.scrub_message("user@1000.service stopped")).to eq("user@1000.service stopped")
    end

    it "NON tocca l'utente su una macchina: non è un indirizzo email e serve a capire il guasto" do
      expect(scrubber.scrub_message("ssh root@10.0.0.9 rifiutata")).to eq("ssh root@10.0.0.9 rifiutata")
    end
  end

  describe "#scrub_headers" do
    it "redige gli header di autenticazione e quelli che portano l'indirizzo di chi chiama" do
      redatti = scrubber.scrub_headers(
        "Accept" => "json", "Authorization" => "Bearer t", "X-Forwarded-For" => "1.2.3.4"
      )

      expect(redatti).to eq(
        "Accept" => "json", "Authorization" => "[FILTERED]", "X-Forwarded-For" => "[FILTERED]"
      )
    end
  end

  describe "#scrub_query_string" do
    it "redige i soli parametri sensibili e conserva la forma della stringa" do
      expect(scrubber.scrub_query_string("plan=pro&token=SECRET")).to eq("plan=pro&token=[FILTERED]")
    end
  end

  describe "#strip_query" do
    it "tiene indirizzo e percorso, butta la parte dopo il punto di domanda" do
      expect(scrubber.strip_query("https://x.test/a?b=c")).to eq("https://x.test/a")
    end

    it "un indirizzo senza query resta identico" do
      expect(scrubber.strip_query("https://x.test/a")).to eq("https://x.test/a")
    end
  end

  # Il canale performance scruba TUTTO il payload (non solo le sezioni libere) e per questo usa una
  # denylist ancorata al segmento: `span_id` contiene "pan", `mapping` contiene "pin". La ricorsione è
  # la stessa, il criterio no — ed è un punto di variazione dichiarato, non una copia dimenticata.
  describe "punti di variazione per il dominio" do
    let(:severo) do
      Class.new do
        include Ingest::PiiScrubbing

        def sensitive_key?(key) = key.to_s == "solo_questa"
        def url_key?(key) = key.to_s == "indirizzo"
      end.new
    end

    it "il criterio di chiave sensibile è sovrascrivibile" do
      expect(severo.scrub_value("solo_questa" => "x", "password" => "y"))
        .to eq("solo_questa" => "[FILTERED]", "password" => "y")
    end

    it "l'elenco delle chiavi che portano un indirizzo è sovrascrivibile" do
      expect(severo.scrub_value("indirizzo" => "https://x.test/a?b=c", "url" => "https://x.test/a?b=c"))
        .to eq("indirizzo" => "https://x.test/a", "url" => "https://x.test/a?b=c")
    end
  end

  # Scenario 1 del ticket: lo stesso dato sporco entra dai tre canali e ne esce ripulito allo stesso
  # modo. Non è una prova di implementazione: è la promessa che il ticket chiede di mantenere.
  describe "la stessa pulizia per errori, log e campioni dei server (Scenario 1)" do
    it "i tre canali usano lo stesso criterio di chiave sensibile" do
      expect(Errors::Ingest::Normalize.new(payload: {}).send(:sensitive_key?, "email")).to be(true)
      expect(Logs::Ingest::Normalize.new(payload: {}).send(:sensitive_key?, "email")).to be(true)
      expect(Servers::Ingest::Normalize.new(payload: {}).send(:sensitive_key?, "email")).to be(true)
    end

    it "un indirizzo con token dentro il testo esce redatto sia dagli errori sia dai log sia dai server" do
      testo = "GET /pay?token=SECRET&plan=pro"
      atteso = "GET /pay?token=[FILTERED]&plan=pro"

      errore = Errors::Ingest::Normalize.call(
        payload: { "breadcrumbs" => { "values" => [ { "message" => testo } ] } }
      )
      log = Logs::Ingest::Normalize.call(payload: { "message" => testo })
      server = Servers::Ingest::Normalize.call(
        payload: { "journal" => { "entries" => [ { "c" => "cur", "t" => 1, "p" => 3, "m" => testo } ] } }
      )

      expect(errore.payload.dig("breadcrumbs", "values", 0, "message")).to eq(atteso)
      expect(log.message).to eq(atteso)
      expect(server.journal_entries.first[:message]).to eq(atteso)
    end

    it "una data nel futuro viene riportata ad adesso su tutti e tre i canali" do
      freeze_time do
        errore = Errors::Ingest::Normalize.call(payload: { "timestamp" => 2.hours.from_now.to_i })
        log = Logs::Ingest::Normalize.call(
          payload: { "message" => "x", "timestamp" => 2.hours.from_now.to_i }
        )
        server = Servers::Ingest::Normalize.call(payload: { "recorded_at" => 2.hours.from_now.iso8601 })

        expect(errore.occurred_at).to eq(Time.current)
        expect(log.occurred_at).to eq(Time.current)
        expect(server.recorded_at).to eq(Time.current)
      end
    end
  end
end
