# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Ingest::Normalize, type: :service do
  def normalize(payload) = described_class.call(payload: payload)

  it "title da exception type + value" do
    n = normalize("exception" => { "values" => [ { "type" => "RuntimeError", "value" => "boom" } ] })
    expect(n.title).to eq("RuntimeError: boom")
  end

  it "title da message in fallback" do
    expect(normalize("message" => "disk full").title).to eq("disk full")
  end

  it "level mappato; sconosciuto → error" do
    expect(normalize("level" => "warning").level).to eq("warning")
    expect(normalize("level" => "bogus").level).to eq("error")
    expect(normalize({}).level).to eq("error")
  end

  describe "occurred_at" do
    it "da epoch float" do
      travel_to(Time.utc(2026, 6, 1, 12)) do
        expect(normalize("timestamp" => Time.utc(2026, 5, 1).to_f).occurred_at).to be_within(1).of(Time.utc(2026, 5, 1))
      end
    end

    it "da stringa ISO8601" do
      expect(normalize("timestamp" => "2026-05-01T10:00:00Z").occurred_at).to be_within(1).of(Time.utc(2026, 5, 1, 10))
    end

    it "mancante → ora corrente" do
      travel_to(Time.utc(2026, 6, 1, 12)) do
        expect(normalize({}).occurred_at).to be_within(1).of(Time.utc(2026, 6, 1, 12))
      end
    end

    it "stringa non parsabile → ora corrente" do
      travel_to(Time.utc(2026, 6, 1, 12)) do
        expect(normalize("timestamp" => "not-a-date").occurred_at).to be_within(1).of(Time.utc(2026, 6, 1, 12))
      end
    end
  end

  it "runtime 'name version'" do
    expect(normalize("contexts" => { "runtime" => { "name" => "ruby", "version" => "3.3.10" } }).runtime).to eq("ruby 3.3.10")
  end

  it "runtime nil se contexts.runtime non è un hash" do
    expect(normalize("contexts" => { "runtime" => "ruby" }).runtime).to be_nil
  end

  describe "device/OS/app context (colonne indicizzate per il breakdown mobile)" do
    it "estrae os_name/os_version da contexts.os" do
      normalized = normalize("contexts" => { "os" => { "name" => "iOS", "version" => "17.4" } })
      expect(normalized.os_name).to eq("iOS")
      expect(normalized.os_version).to eq("17.4")
    end

    it "estrae app_version da contexts.app (app_version + build_number → semver+build)" do
      normalized = normalize("contexts" => { "app" => { "app_version" => "1.2.0", "build_number" => "45" } })
      expect(normalized.app_version).to eq("1.2.0+45")
    end

    it "accetta anche app_build (nome campo degli SDK Sentry ufficiali)" do
      normalized = normalize("contexts" => { "app" => { "app_version" => "1.2.0", "app_build" => "99" } })
      expect(normalized.app_version).to eq("1.2.0+99")
    end

    it "app_version senza build resta nuda" do
      expect(normalize("contexts" => { "app" => { "app_version" => "1.2.0" } }).app_version).to eq("1.2.0")
    end

    it "tutti nil senza contexts (eventi server-side)" do
      normalized = normalize({})
      expect(normalized.os_name).to be_nil
      expect(normalized.os_version).to be_nil
      expect(normalized.app_version).to be_nil
    end

    it "difensivo su forme non-Hash" do
      normalized = normalize("contexts" => { "os" => "android", "app" => 42 })
      expect(normalized.os_name).to be_nil
      expect(normalized.app_version).to be_nil
    end
  end

  it "title 'Error' in fallback senza exception/message/transaction" do
    expect(normalize({}).title).to eq("Error")
  end

  it "scrub no-op se non c'è request né user" do
    expect(normalize("level" => "error").payload).to eq("level" => "error")
  end

  it "scrub: request con headers non-hash resta invariato (cookies/env comunque rimossi)" do
    n = normalize("request" => { "headers" => "raw", "cookies" => { "s" => "x" } })
    expect(n.payload["request"]).to eq("headers" => "raw")
  end

  describe "PII" do
    let(:payload) do
      {
        "user" => { "id" => "42", "email" => "a@b.com", "ip_address" => "1.2.3.4", "username" => "bob" },
        "request" => {
          "cookies" => { "session" => "secret" },
          "env" => { "REMOTE_ADDR" => "1.2.3.4" },
          "headers" => { "Authorization" => "Bearer x", "Accept" => "json" }
        }
      }
    end

    it "user_hash deterministico e non in chiaro" do
      n = normalize(payload)
      expect(n.user_hash).to eq(normalize(payload).user_hash)
      expect(n.user_hash).not_to include("a@b.com")
      expect(n.user_hash).to match(/\A[0-9a-f]{16}\z/)
    end

    it "scrub: rimuove email/ip/username, cookies, env; redige gli header auth" do
      n = normalize(payload)
      expect(n.payload["user"]).to eq("id" => "42")
      expect(n.payload["request"]).not_to have_key("cookies")
      expect(n.payload["request"]).not_to have_key("env")
      # gli header sensibili sono redatti (chiave preservata, valore [FILTERED]) invece che rimossi.
      expect(n.payload["request"]["headers"]).to eq("Authorization" => "[FILTERED]", "Accept" => "json")
    end

    it "user_hash nil senza utente" do
      expect(normalize({}).user_hash).to be_nil
    end
  end

  it "event_id passthrough" do
    expect(normalize("event_id" => "abc123").event_id).to eq("abc123")
  end

  describe "trace_id (correlazione log↔errori)" do
    it "estrae trace_id top-level" do
      expect(normalize("trace_id" => "abc123trace").trace_id).to eq("abc123trace")
    end

    it "trace_id nil se assente o blank" do
      expect(normalize({}).trace_id).to be_nil
      expect(normalize("trace_id" => "").trace_id).to be_nil
    end

    it "fallback a contexts.trace.trace_id (formato SDK Sentry ufficiali)" do
      payload = { "contexts" => { "trace" => { "trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736" } } }
      expect(normalize(payload).trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    end

    it "il trace_id top-level (gemma nativa) vince su contexts.trace" do
      payload = { "trace_id" => "nativo", "contexts" => { "trace" => { "trace_id" => "sentry" } } }
      expect(normalize(payload).trace_id).to eq("nativo")
    end

    it "contexts.trace malformato o senza trace_id → nil, senza errori" do
      expect(normalize("contexts" => "stringa").trace_id).to be_nil
      expect(normalize("contexts" => { "trace" => "stringa" }).trace_id).to be_nil
      expect(normalize("contexts" => { "trace" => {} }).trace_id).to be_nil
      expect(normalize("contexts" => { "trace" => { "trace_id" => 123 } }).trace_id).to eq("123")
    end
  end

  describe "handled (mechanism.handled — crash veri vs catture volontarie, CYRA-49)" do
    def exception_with(mechanism)
      { "exception" => { "values" => [ { "type" => "E", "value" => "x" }.merge(mechanism) ] } }
    end

    it "true da una cattura volontaria (capture_exception, mechanism.handled=true)" do
      expect(normalize(exception_with("mechanism" => { "type" => "generic", "handled" => true })).handled).to be(true)
    end

    it "false da un crash non gestito (mechanism.handled=false)" do
      expect(normalize(exception_with("mechanism" => { "handled" => false })).handled).to be(false)
    end

    it "nil quando l'exception non porta mechanism" do
      expect(normalize(exception_with({})).handled).to be_nil
    end

    it "nil senza exception (capture_message)" do
      expect(normalize("message" => "disk full").handled).to be_nil
    end

    it "nil se mechanism non è un Hash o handled non è un vero booleano (niente coercizione)" do
      expect(normalize(exception_with("mechanism" => "generic")).handled).to be_nil
      expect(normalize(exception_with("mechanism" => { "handled" => "true" })).handled).to be_nil
      expect(normalize(exception_with("mechanism" => { "handled" => 1 })).handled).to be_nil
      expect(normalize(exception_with("mechanism" => { "type" => "generic" })).handled).to be_nil
    end

    it "usa il mechanism dell'ULTIMA exception (catena, come title/culprit)" do
      n = normalize("exception" => { "values" => [
        { "type" => "Inner", "value" => "x", "mechanism" => { "handled" => true } },
        { "type" => "Outer", "value" => "y", "mechanism" => { "handled" => false } }
      ] })
      expect(n.handled).to be(false)
    end
  end

  describe "campi arricchiti (request.data + breadcrumbs)" do
    it "preserva i breadcrumbs ma scruba le chiavi sensibili in data" do
      n = normalize(
        "breadcrumbs" => { "values" => [
          { "category" => "query", "message" => "SELECT ?",
            "data" => { "name" => "User Load", "password" => "x" } }
        ] }
      )
      crumb = n.payload.dig("breadcrumbs", "values").first
      expect(crumb["message"]).to eq("SELECT ?")
      expect(crumb["data"]).to eq("name" => "User Load", "password" => "[FILTERED]")
    end

    it "scruba i parametri sensibili nel body della request (request.data), email inclusa" do
      n = normalize("request" => { "method" => "POST", "data" => { "name" => "Mario", "email" => "a@b.com", "token" => "t" } })
      expect(n.payload["request"]["method"]).to eq("POST")
      expect(n.payload["request"]["data"]).to eq("name" => "Mario", "email" => "[FILTERED]", "token" => "[FILTERED]")
    end

    it "preserva user.id e request.url (non-PII) nel payload conservato" do
      n = normalize(
        "user" => { "id" => "9", "email" => "a@b.com" },
        "request" => { "method" => "GET", "url" => "https://x/orders/9" },
        "tags" => { "area" => "checkout" }
      )
      expect(n.payload["user"]).to eq("id" => "9")
      expect(n.payload["request"]).to eq("method" => "GET", "url" => "https://x/orders/9")
      expect(n.context["tags"]).to eq("area" => "checkout")
    end
  end

  describe "B3: scrub di tags/extra/contexts (difesa in profondità)" do
    let(:payload) do
      {
        "tags" => { "area" => "checkout", "api_key" => "sk_live_x" },
        "extra" => { "order_id" => "9", "password" => "p" },
        "contexts" => {
          "runtime" => { "name" => "ruby", "version" => "4.0" },
          "auth" => { "token" => "t", "scheme" => "bearer" }
        }
      }
    end

    it "redige le chiavi sensibili nel context preservando struttura e valori non sensibili" do
      n = normalize(payload)
      expect(n.context["tags"]).to eq("area" => "checkout", "api_key" => "[FILTERED]")
      expect(n.context["extra"]).to eq("order_id" => "9", "password" => "[FILTERED]")
      expect(n.context.dig("contexts", "runtime")).to eq("name" => "ruby", "version" => "4.0")
      expect(n.context.dig("contexts", "auth")).to eq("token" => "[FILTERED]", "scheme" => "bearer")
    end

    it "redige anche nel payload conservato (top-level tags/extra/contexts), runtime intatto" do
      n = normalize(payload)
      expect(n.payload.dig("tags", "api_key")).to eq("[FILTERED]")
      expect(n.payload.dig("extra", "password")).to eq("[FILTERED]")
      expect(n.payload.dig("contexts", "auth", "token")).to eq("[FILTERED]")
      expect(n.payload.dig("contexts", "runtime")).to eq("name" => "ruby", "version" => "4.0")
    end
  end

  describe "rami ai confini" do
    it "exception con type e value assenti → title nil (presence& else)" do
      n = normalize("exception" => { "values" => [ {} ] })
      expect(n.title).to be_nil
    end

    it "exception.values array vuoto ([]) → title da message, nessun crash su values.last" do
      n = normalize("exception" => { "values" => [] }, "message" => "disco pieno")
      expect(n.title).to eq("disco pieno")
      expect(n.culprit).to be_nil
    end

    it "title da message hash 'formatted' quando non c'è exception (|| formatted)" do
      n = normalize("message" => { "formatted" => "disco pieno" })
      expect(n.title).to eq("disco pieno")
    end

    it "user hash senza id/email/ip → user_hash nil (ramo id.present? else)" do
      n = normalize("user" => { "segment" => "beta" })
      expect(n.user_hash).to be_nil
    end

    it "breadcrumb non-hash o senza data → nessuno scrub (ramo if else), nessun crash" do
      n = normalize("breadcrumbs" => { "values" => [ "stringa", { "message" => "no data" } ] })
      expect(n.payload.dig("breadcrumbs", "values")).to eq([ "stringa", { "message" => "no data" } ])
    end
  end

  describe "hardening 2026-07-09 (audit ciclo errore)" do
    it "strippa i null byte da title/server_name/payload (evita il crash PG e la perdita evento)" do
      nul = 0.chr
      n = normalize(
        "exception" => { "values" => [ { "type" => "E", "value" => "boom#{nul}bar" } ] },
        "server_name" => "web#{nul}1",
        "extra" => { "note" => "a#{nul}b" }
      )
      expect(n.title).to eq("E: boombar")
      expect(n.server_name).to eq("web1")
      expect(n.payload.dig("extra", "note")).to eq("ab")
    end

    it "clampa un timestamp nel futuro a now" do
      n = normalize("timestamp" => (Time.current + 10.years).to_f)
      expect(n.occurred_at).to be <= Time.current + 1
    end

    it "interpreta un epoch in millisecondi (JS Date.now())" do
      target = Time.utc(2026, 5, 20, 8, 0, 0)
      n = normalize("timestamp" => (target.to_f * 1000).to_i)
      expect(n.occurred_at).to be_within(1).of(target)
    end

    it "scruba le chiavi sensibili dentro array-di-hash (ricorsione su Array)" do
      n = normalize("extra" => { "items" => [ { "sku" => "A1", "card" => "4111" }, { "sku" => "B2", "cvv" => "123" } ] })
      expect(n.context.dig("extra", "items")).to eq([
        { "sku" => "A1", "card" => "[FILTERED]" },
        { "sku" => "B2", "cvv" => "[FILTERED]" }
      ])
    end

    it "redige gli header per nome case-insensitive (authorization minuscolo, X-Api-Key, X-Forwarded-For)" do
      n = normalize("request" => { "headers" => {
        "authorization" => "Bearer x", "X-Api-Key" => "sk_live", "X-Forwarded-For" => "1.2.3.4", "Accept" => "json"
      } })
      expect(n.payload["request"]["headers"]).to eq(
        "authorization" => "[FILTERED]", "X-Api-Key" => "[FILTERED]", "X-Forwarded-For" => "[FILTERED]", "Accept" => "json"
      )
    end

    it "scruba i parametri sensibili della query_string e strippa la query dall'url" do
      n = normalize("request" => {
        "url" => "https://app/reset?token=SECRET&email=u@x.com",
        "query_string" => "token=SECRET&email=u@x.com&page=2"
      })
      expect(n.payload["request"]["url"]).to eq("https://app/reset")
      expect(n.payload["request"]["query_string"]).to eq("token=[FILTERED]&email=[FILTERED]&page=2")
    end

    it "redige i vars dei frame dello stacktrace (payload + colonna stacktrace)" do
      n = normalize("exception" => { "values" => [ {
        "type" => "E", "value" => "x",
        "stacktrace" => { "frames" => [ { "filename" => "a.rb", "vars" => { "user" => "mario", "password" => "hunter2" } } ] }
      } ] })
      expect(n.payload.dig("exception", "values", 0, "stacktrace", "frames", 0, "vars")).to eq(
        "user" => "mario", "password" => "[FILTERED]"
      )
      expect(n.stacktrace.dig("frames", 0, "vars")).to eq("user" => "mario", "password" => "[FILTERED]")
    end

    # CYRA-379: il punto del codice (filename/module) NON è PII e NON va oscurato dal backend — solo
    # i `vars` dei frame lo sono. Se arriva "[FILTERED]" è lo scrubber dell'SDK del progetto, non noi:
    # questo test blinda la garanzia lato ingest così lo stacktrace resta leggibile (Definition of Done).
    it "NON oscura filename/module dei frame (il punto del codice resta leggibile)" do
      n = normalize("exception" => { "values" => [ {
        "type" => "E", "value" => "x",
        "stacktrace" => { "frames" => [ {
          "filename" => "/app/app/views/events/show.html.erb", "module" => "Events::Show",
          "function" => "call", "vars" => { "password" => "hunter2" }
        } ] }
      } ] })

      %i[stacktrace payload].each do |source|
        frame = if source == :stacktrace
          n.stacktrace.dig("frames", 0)
        else
          n.payload.dig("exception", "values", 0, "stacktrace", "frames", 0)
        end
        expect(frame["filename"]).to eq("/app/app/views/events/show.html.erb")
        expect(frame["module"]).to eq("Events::Show")
        expect(frame["function"]).to eq("call")
        expect(frame["vars"]).to eq("password" => "[FILTERED]") # solo i vars restano oscurati
      end
    end

    # CYRA-379: coerente col punto sopra — il culprit deriva da filename/module + function, quindi con
    # frame reali resta interamente leggibile (nessun "[FILTERED]" introdotto dal backend).
    it "il culprit da un frame reale resta leggibile (nessun oscuramento lato backend)" do
      n = normalize("exception" => { "values" => [ {
        "type" => "E", "value" => "x",
        "stacktrace" => { "frames" => [ {
          "filename" => "/app/jobs/orders_job.rb", "function" => "deserialize", "in_app" => true
        } ] }
      } ] })
      expect(n.culprit).to eq("/app/jobs/orders_job.rb in deserialize")
    end

    it "la denylist estesa filtra email e phone nei tag" do
      n = normalize("tags" => { "user.email" => "m@x.it", "phone" => "+39055", "area" => "pay" })
      expect(n.context["tags"]).to eq("user.email" => "[FILTERED]", "phone" => "[FILTERED]", "area" => "pay")
    end

    it "redige i valori sensibili nel message del breadcrumb (URL con token)" do
      n = normalize("breadcrumbs" => { "values" => [ { "message" => "GET /pay?token=SECRET&plan=pro" } ] })
      expect(n.payload.dig("breadcrumbs", "values", 0, "message")).to eq("GET /pay?token=[FILTERED]&plan=pro")
    end
  end
end
