# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Ingest::Normalize do
  def normalize(payload)
    described_class.call(payload: payload)
  end

  it "mappa i campi del payload della gemma" do
    n = normalize(
      "event_id" => "abc", "timestamp" => "2026-06-28T10:00:00Z", "level" => "warning",
      "message" => "disk almost full", "attributes" => { "disk" => "sda1" },
      "logger" => "system", "trace_id" => "t-1", "environment" => "production", "release" => "v1.2"
    )
    expect(n.event_id).to eq("abc")
    expect(n.occurred_at).to eq(Time.zone.parse("2026-06-28T10:00:00Z"))
    expect(n.level).to eq("warning")
    expect(n.message).to eq("disk almost full")
    expect(n.data).to eq("disk" => "sda1")
    expect(n.logger_name).to eq("system")
    expect(n.trace_id).to eq("t-1")
    expect(n.environment).to eq("production")
    expect(n.release).to eq("v1.2")
  end

  it "usa 'info' per un level sconosciuto o assente" do
    expect(normalize("message" => "x", "level" => "verbose").level).to eq("info")
    expect(normalize("message" => "x").level).to eq("info")
  end

  it "genera un event_id se assente" do
    expect(normalize("message" => "x").event_id).to be_present
  end

  it "scruba le chiavi sensibili negli attributes (ricorsivo)" do
    n = normalize(
      "message" => "login",
      "attributes" => { "password" => "hunter2", "nested" => { "api_key" => "k", "ok" => "v" } }
    )
    expect(n.data["password"]).to eq("[FILTERED]")
    expect(n.data["nested"]["api_key"]).to eq("[FILTERED]")
    expect(n.data["nested"]["ok"]).to eq("v")
  end

  it "scruba le chiavi sensibili anche dentro gli array di hash" do
    n = normalize(
      "message" => "x",
      "attributes" => { "users" => [ { "password" => "p", "name" => "ok" }, { "token" => "t" } ] }
    )
    expect(n.data["users"]).to eq([ { "password" => "[FILTERED]", "name" => "ok" }, { "token" => "[FILTERED]" } ])
  end

  it "ritorna {} per attributes assenti o non-hash" do
    expect(normalize("message" => "x").data).to eq({})
    expect(normalize("message" => "x", "attributes" => "boom").data).to eq({})
  end

  describe "parse del timestamp" do
    it "accetta epoch numerico" do
      expect(normalize("message" => "x", "timestamp" => 1_700_000_000).occurred_at)
        .to eq(Time.zone.at(1_700_000_000))
    end

    it "ripiega su Time.current per un timestamp invalido" do
      freeze_time do
        expect(normalize("message" => "x", "timestamp" => "not-a-date").occurred_at).to eq(Time.current)
        expect(normalize("message" => "x").occurred_at).to eq(Time.current)
      end
    end

    it "interpreta un epoch in millisecondi (errore Date.now() lato client)" do
      expect(normalize("message" => "x", "timestamp" => 1_700_000_000_000).occurred_at)
        .to eq(Time.zone.at(1_700_000_000))
    end

    it "clampa a now un occurred_at troppo nel futuro (dato corrotto)" do
      freeze_time do
        future = (Time.current + 5.days).iso8601
        expect(normalize("message" => "x", "timestamp" => future).occurred_at).to eq(Time.current)
      end
    end

    # CYRA-735: la difesa dal numero che non è una data esisteva solo nel canale errori. Con la regola
    # condivisa vale anche qui: prima un timestamp così faceva morire il job, e con lui l'intero batch.
    it "un timestamp che non è un numero rappresentabile → adesso, senza far morire il batch" do
      freeze_time do
        expect(normalize("message" => "x", "timestamp" => Float::INFINITY).occurred_at).to eq(Time.current)
      end
    end
  end

  it "payload non-hash → trattato come vuoto (ramo else), nessun crash" do
    n = normalize("non-un-hash")
    expect(n.level).to eq("info")
    expect(n.message).to eq("")
    expect(n.data).to eq({})
  end

  it "strippa i null byte da message e attributes (Postgres li rifiuta: poison-pill dell'intero batch)" do
    nul = 0.chr
    n = normalize("message" => "boom#{nul}tail", "attributes" => { "k" => "v#{nul}x" })
    expect(n.message).to eq("boomtail")
    expect(n.data).to eq("k" => "vx")
  end

  it "tronca il message oltre il cap di byte (anti storage/broadcast exhaustion)" do
    n = normalize("message" => "a" * 20_000)
    expect(n.message.bytesize).to be <= Logs::Ingest::Normalize::MESSAGE_MAX_BYTES
  end

  # CYRA-62: senza cap, un client buggato/compromesso POSTa 1000 item con attributes da MB ciascuno →
  # ~GB nella tabella più grande + broadcast realtime gonfiati. Il cap è sulla dimensione serializzata
  # degli attributes (il jsonb `data`), come per il message.
  describe "cap sulla dimensione serializzata degli attributes" do
    let(:cap) { Logs::Ingest::Normalize::DATA_MAX_BYTES }

    it "scarta gli attributes oltre il cap e li rimpiazza con un marker (dimensione originale preservata)" do
      n = normalize("message" => "x", "attributes" => { "blob" => "a" * 200_000 })
      expect(n.data["_truncated"]).to be(true)
      expect(n.data["_original_bytes"]).to be > cap
      expect(n.data.to_json.bytesize).to be <= cap
    end

    # Confine +1 byte: `{ "k" => value }.to_json` serializza in 8 + value.bytesize byte (ASCII).
    it "preserva gli attributes esattamente al cap (confine X)" do
      value = "a" * (cap - 8)
      n = normalize("message" => "x", "attributes" => { "k" => value })
      expect(n.data).to eq("k" => value)
    end

    it "scarta gli attributes appena oltre il cap (confine X+1)" do
      value = "a" * (cap - 7)
      n = normalize("message" => "x", "attributes" => { "k" => value })
      expect(n.data["_truncated"]).to be(true)
    end

    # Il cap misura la dimensione REALE persistita (dopo lo scrub): un valore sensibile enorme viene
    # ridotto a [FILTERED] e NON triggera il cap → gli attributes restano, solo la PII è redatta.
    it "misura la dimensione dopo lo scrub PII (valore sensibile enorme non triggera il cap)" do
      n = normalize("message" => "x", "attributes" => { "password" => "a" * 200_000, "ok" => "v" })
      expect(n.data).to eq("password" => "[FILTERED]", "ok" => "v")
    end
  end

  # CYRA-58: pre-check leggero usato dal controller nel thread web — verifica solo la shape del
  # message, senza il deep_clean dell'intero payload né lo scrub ricorsivo degli attributes.
  describe ".message_present?" do
    it "true per un Hash con message non vuoto" do
      expect(described_class.message_present?("message" => "hi")).to be(true)
    end

    it "false per non-Hash, hash senza message, message vuoto o di soli spazi" do
      expect(described_class.message_present?("nope")).to be(false)
      expect(described_class.message_present?(42)).to be(false)
      expect(described_class.message_present?({})).to be(false)
      expect(described_class.message_present?("message" => "")).to be(false)
      expect(described_class.message_present?("message" => "   ")).to be(false)
    end

    it "false per un message di soli null byte (coerente col filtro dopo lo strip)" do
      expect(described_class.message_present?("message" => 0.chr * 3)).to be(false)
    end

    it "non istanzia la Normalize completa (nessun deep_clean/scrub nel pre-check)" do
      expect(described_class).not_to receive(:new)
      described_class.message_present?("message" => "hi", "attributes" => { "a" => { "b" => "c" } })
    end
  end

  # CYRA-214: la denylist PII del canale log era più corta di quella (canonica) del canale errori e
  # lasciava passare email, telefono, data di nascita e altri dati personali negli attributes. Da
  # CYRA-735 la lista non è più copiata: è UNA, e i due canali la leggono dallo stesso posto.
  # Denylist canonica: closeyourit-docs/decisions/2026-07-09-pii-scrub-parity.md.
  describe "parità della denylist PII col canale errori (CYRA-214)" do
    it "legge la stessa unica lista di termini sensibili del canale errori" do
      expect(described_class::SENSITIVE_KEY).to be(Ingest::PiiScrubbing::SENSITIVE_KEY)
      expect(described_class::SENSITIVE_KEY).to be(Errors::Ingest::Normalize::SENSITIVE_KEY)
    end

    it "redige negli attributes i termini che prima passavano (email, telefono, nascita, sessione, ...)" do
      n = normalize(
        "message" => "signup",
        "attributes" => {
          "email" => "a@b.com", "phone" => "+39055", "telephone" => "+39055", "mobile" => "+39333",
          "dob" => "1990-01-01", "birth_date" => "1990-01-01", "passport" => "AA123",
          "pin" => "1234", "session" => "s", "bearer" => "tok", "pan" => "4111", "area" => "signup"
        }
      )
      expect(n.data).to eq(
        "email" => "[FILTERED]", "phone" => "[FILTERED]", "telephone" => "[FILTERED]", "mobile" => "[FILTERED]",
        "dob" => "[FILTERED]", "birth_date" => "[FILTERED]", "passport" => "[FILTERED]",
        "pin" => "[FILTERED]", "session" => "[FILTERED]", "bearer" => "[FILTERED]", "pan" => "[FILTERED]",
        "area" => "signup"
      )
    end

    # Scenario 1: un log con dentro un indirizzo email → al posto dell'indirizzo il segnaposto.
    # (Scenario 2 — indipendenza dal mittente — è coperto end-to-end in spec/requests/api/v1/logs_spec.rb.)
    it "nasconde l'email in una riga di log, come fa il canale errori (Scenario 1)" do
      n = normalize("message" => "login", "attributes" => { "email" => "user@example.com" })
      expect(n.data["email"]).to eq("[FILTERED]")
    end
  end

  # CYRA-735: il testo del messaggio era l'unica parte del canale log che nessuno redigeva, mentre il
  # canale errori lo faceva già sul testo dei breadcrumb. Ora la policy è la stessa per tutti.
  describe "rimozione dei dati personali dal testo del messaggio (CYRA-735)" do
    it "redige il valore sensibile scritto nel messaggio e lascia leggibile la frase" do
      n = normalize("message" => "chiamata a /pay?token=SECRET&plan=pro fallita")
      expect(n.message).to eq("chiamata a /pay?token=[FILTERED]&plan=pro fallita")
    end

    it "non tocca il resto del testo: non è una censura, è una redazione mirata" do
      n = normalize("message" => "connessione rifiutata su porta 5432")
      expect(n.message).to eq("connessione rifiutata su porta 5432")
    end

    it "non svuota il messaggio, quindi il pre-filtro del controller resta coerente col job" do
      n = normalize("message" => "password=hunter2")

      expect(n.message).to eq("password=[FILTERED]")
      expect(described_class.message_present?("message" => "password=hunter2")).to be(true)
    end

    it "il tetto di byte vale DOPO la redazione (il segnaposto è più lungo del valore)" do
      n = normalize("message" => "#{"a" * 15_990} token=x")
      expect(n.message.bytesize).to be <= described_class::MESSAGE_MAX_BYTES
    end

    it "riconosce ancora l'identificativo di richiesta scritto nel messaggio" do
      n = normalize("message" => "[e146fed6-1a2b-4c3d-8e4f-556677889900] token=SECRET")

      expect(n.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
      expect(n.message).to end_with("token=[FILTERED]")
    end

    it "strippa la query dagli indirizzi negli attributes (parità col canale errori)" do
      n = normalize("message" => "x", "attributes" => { "url" => "https://x.test/pay?token=SECRET" })
      expect(n.data["url"]).to eq("https://x.test/pay")
    end
  end

  # CYRA-345: quando il client NON manda il campo strutturato trace_id, l'identificativo della
  # richiesta è spesso già scritto in chiaro nel messaggio (prefisso TaggedLogging di Rails, Job ID
  # di ActiveJob). Riconoscerlo lì e normalizzarlo sulla colonna del join ricuce la correlazione
  # log↔errori promessa dalla guida, senza dipendere dal mittente. La provenienza è marcata.
  describe "fallback: estrazione del trace id dal messaggio (CYRA-345)" do
    it "riconosce il request id dal prefisso Rails [uuid] a inizio riga" do
      n = normalize("message" => "[e146fed6-1a2b-4c3d-8e4f-556677889900] ActiveRecord::RecordNotFound")
      expect(n.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
      expect(n.trace_id_extracted).to be(true)
    end

    it "riconosce il job id dal pattern 'Job ID: uuid' di ActiveJob" do
      n = normalize("message" => "Performing HardJob (Job ID: 0c4f2e10-aaaa-4bbb-8ccc-1234567890ab) from Async")
      expect(n.trace_id).to eq("0c4f2e10-aaaa-4bbb-8ccc-1234567890ab")
      expect(n.trace_id_extracted).to be(true)
    end

    it "il campo strutturato ha la precedenza e NON viene marcato come estratto" do
      n = normalize(
        "message" => "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom", "trace_id" => "structured-1"
      )
      expect(n.trace_id).to eq("structured-1")
      expect(n.trace_id_extracted).to be(false)
    end

    it "non cattura un UUID citato in mezzo al messaggio (evita falsi positivi)" do
      n = normalize("message" => "utente e146fed6-1a2b-4c3d-8e4f-556677889900 non trovato")
      expect(n.trace_id).to be_nil
      expect(n.trace_id_extracted).to be(false)
    end

    # CYRA-559: il messaggio di eccezione che Rails emette davvero NON comincia con la parentesi —
    # DebugExceptions logga prima una riga vuota, quindi il tag arriva dopo due spazi e un a capo.
    # Ancorato a inizio STRINGA il pattern non combaciava mai: il codice era scritto nel messaggio
    # (fino a 25 volte, una per riga taggata) e la pagina rispondeva che non c'era.
    it "riconosce il request id nel formato reale di Rails (spazi e a capo prima del tag)" do
      n = normalize("message" => "  \n[e146fed6-1a2b-4c3d-8e4f-556677889900] ActiveRecord::RecordNotFound (Couldn't find User)")
      expect(n.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
      expect(n.trace_id_extracted).to be(true)
    end

    it "riconosce il tag anche quando compare solo su una riga successiva del messaggio" do
      message = "Completed 500 Internal Server Error\n" \
                "[e146fed6-1a2b-4c3d-8e4f-556677889900] boom\n" \
                "[e146fed6-1a2b-4c3d-8e4f-556677889900] backtrace"
      expect(normalize("message" => message).trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
    end

    it "riconosce il tag rientrato (indentazione del backtrace)" do
      n = normalize("message" => "\t  [e146fed6-1a2b-4c3d-8e4f-556677889900] app/models/user.rb:12")
      expect(n.trace_id).to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
    end

    # Il vincolo POSIZIONALE resta: si allarga a inizio RIGA, non ovunque. Un tag citato a metà frase
    # non è il prefisso TaggedLogging di quella riga e unirebbe richieste diverse.
    it "non cattura un tag [uuid] citato a metà riga" do
      n = normalize("message" => "richiesta [e146fed6-1a2b-4c3d-8e4f-556677889900] gestita altrove")
      expect(n.trace_id).to be_nil
      expect(n.trace_id_extracted).to be(false)
    end

    it "senza identificativo riconoscibile lascia trace_id nil e provenienza falsa" do
      n = normalize("message" => "semplice riga di log")
      expect(n.trace_id).to be_nil
      expect(n.trace_id_extracted).to be(false)
    end

    describe ".trace_id_from_message (fonte di verità condivisa con il backfill)" do
      it "estrae dai due pattern posizionali, altrimenti nil" do
        expect(described_class.trace_id_from_message("[e146fed6-1a2b-4c3d-8e4f-556677889900] x"))
          .to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
        expect(described_class.trace_id_from_message("Job ID: 0c4f2e10-aaaa-4bbb-8ccc-1234567890ab"))
          .to eq("0c4f2e10-aaaa-4bbb-8ccc-1234567890ab")
        expect(described_class.trace_id_from_message("nessun id qui")).to be_nil
        expect(described_class.trace_id_from_message(nil)).to be_nil
      end

      it "riconosce il tag a inizio riga anche preceduto da spazi o a capo (CYRA-559)" do
        expect(described_class.trace_id_from_message("  \n[e146fed6-1a2b-4c3d-8e4f-556677889900] x"))
          .to eq("e146fed6-1a2b-4c3d-8e4f-556677889900")
      end
    end
  end
end
