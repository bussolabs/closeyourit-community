# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Ingest::Normalize do
  it "templatizza lo SQL nella signature (slow_query): literal diversi → stessa signature" do
    n1 = described_class.call(payload: { "kind" => "slow_query", "sql" => "SELECT * FROM t WHERE id = 1", "duration_ms" => 10 })
    n2 = described_class.call(payload: { "kind" => "slow_query", "sql" => "SELECT * FROM t WHERE id = 999", "duration_ms" => 10 })
    expect(n1.signature).to eq(n2.signature)
  end

  it "usa la label come signature (slow_method)" do
    normalized = described_class.call(payload: { "kind" => "slow_method", "label" => "Checkout#total", "duration_ms" => 10 })
    expect(normalized.signature).to include("Checkout#total")
  end

  it "genera un sample_id se mancante" do
    normalized = described_class.call(payload: { "kind" => "slow_query", "sql" => "SELECT 1", "duration_ms" => 10 })
    expect(normalized.sample_id).to be_present
  end

  it "tiene kind nil se non valido" do
    normalized = described_class.call(payload: { "kind" => "bogus", "duration_ms" => 10 })
    expect(normalized.kind).to be_nil
  end

  describe "performance_issue" do
    it "accetta il kind performance_issue" do
      n = described_class.call(payload: {
        "kind" => "performance_issue", "subtype" => "n_plus_one",
        "sql" => "SELECT * FROM t WHERE id = 1", "duration_ms" => 50
      })
      expect(n.kind).to eq("performance_issue")
    end

    it "porta subtype e trace_id nel normalized" do
      n = described_class.call(payload: {
        "kind" => "performance_issue", "subtype" => "n_plus_one", "trace_id" => "req-abc",
        "sql" => "SELECT 1", "duration_ms" => 50
      })
      expect(n.subtype).to eq("n_plus_one")
      expect(n.trace_id).to eq("req-abc")
    end

    it "signature n_plus_one = subtype + sql templatizzato + call-site (literal diversi → stessa)" do
      base = { "kind" => "performance_issue", "subtype" => "n_plus_one",
               "source" => "app/models/order.rb:42", "duration_ms" => 50 }
      s1 = described_class.call(payload: base.merge("sql" => "SELECT * FROM users WHERE id = 1")).signature
      s2 = described_class.call(payload: base.merge("sql" => "SELECT * FROM users WHERE id = 999")).signature
      expect(s1).to eq(s2)
      expect(s1).to include("n_plus_one")
    end

    it "stesso SQL ma call-site diverso → signature diversa" do
      base = { "kind" => "performance_issue", "subtype" => "n_plus_one", "sql" => "SELECT 1", "duration_ms" => 50 }
      s1 = described_class.call(payload: base.merge("source" => "a.rb:1")).signature
      s2 = described_class.call(payload: base.merge("source" => "b.rb:2")).signature
      expect(s1).not_to eq(s2)
    end

    it "slow_request usa la route nella signature" do
      n = described_class.call(payload: {
        "kind" => "performance_issue", "subtype" => "slow_request",
        "route" => "OrdersController#index", "duration_ms" => 1200
      })
      expect(n.signature).to include("OrdersController#index")
    end

    it "high_query_count raggruppa per route (il client manda route, non sql)" do
      base = { "kind" => "performance_issue", "subtype" => "high_query_count", "duration_ms" => 800 }
      s1 = described_class.call(payload: base.merge("route" => "OrdersController#index")).signature
      s2 = described_class.call(payload: base.merge("route" => "OrdersController#index")).signature
      s3 = described_class.call(payload: base.merge("route" => "UsersController#show")).signature
      expect(s1).to eq(s2)
      expect(s1).not_to eq(s3)
      expect(s1).to include("OrdersController#index")
    end

    it "slow_external_http usa host + path templatizzato (id diversi → stessa signature)" do
      base = { "kind" => "performance_issue", "subtype" => "slow_external_http",
               "http_host" => "api.stripe.com", "duration_ms" => 900 }
      s1 = described_class.call(payload: base.merge("http_url" => "https://api.stripe.com/v1/charges/ch_111")).signature
      s2 = described_class.call(payload: base.merge("http_url" => "https://api.stripe.com/v1/charges/ch_999")).signature
      expect(s1).to eq(s2)
      expect(s1).to include("api.stripe.com")
    end

    it "repeated_http (N chiamate identiche, mobile) usa host + path come slow_external_http" do
      base = { "kind" => "performance_issue", "subtype" => "repeated_http",
               "http_host" => "api.x.it", "duration_ms" => 300 }
      s1 = described_class.call(payload: base.merge("http_url" => "/v1/items/111")).signature
      s2 = described_class.call(payload: base.merge("http_url" => "/v1/items/999")).signature
      expect(s1).to eq(s2)
      expect(s1).to include("api.x.it")
    end

    it "jank raggruppa per route/schermo" do
      base = { "kind" => "performance_issue", "subtype" => "jank", "duration_ms" => 32 }
      s1 = described_class.call(payload: base.merge("route" => "FeedScreen")).signature
      s2 = described_class.call(payload: base.merge("route" => "FeedScreen")).signature
      s3 = described_class.call(payload: base.merge("route" => "ProfileScreen")).signature
      expect(s1).to eq(s2)
      expect(s1).not_to eq(s3)
      expect(s1).to include("FeedScreen")
    end

    it "rebuild_storm raggruppa per widget (source)" do
      base = { "kind" => "performance_issue", "subtype" => "rebuild_storm", "duration_ms" => 0 }
      s1 = described_class.call(payload: base.merge("source" => "ProductCard")).signature
      s2 = described_class.call(payload: base.merge("source" => "ProductCard")).signature
      s3 = described_class.call(payload: base.merge("source" => "AvatarTile")).signature
      expect(s1).to eq(s2)
      expect(s1).not_to eq(s3)
      expect(s1).to include("ProductCard")
    end
  end

  describe "occurred_at" do
    it "da epoch numerico (ramo when Numeric)" do
      travel_to(Time.utc(2026, 6, 1, 12)) do
        n = described_class.call(payload: {
          "kind" => "slow_query", "sql" => "SELECT 1", "duration_ms" => 5,
          "occurred_at" => Time.utc(2026, 5, 1).to_f
        })
        expect(n.occurred_at).to be_within(1).of(Time.utc(2026, 5, 1))
      end
    end

    it "da stringa ISO8601 valida (ramo when String) → parsata" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "sql" => "SELECT 1", "duration_ms" => 5,
        "occurred_at" => "2026-05-01T10:00:00Z"
      })
      expect(n.occurred_at).to be_within(1).of(Time.utc(2026, 5, 1, 10))
    end

    # CYRA-53: una stringa non parsabile (mese 13/giorno 45) ripiega su Time.current SENZA sollevare —
    # il campione non va perso, ma il timestamp storico collassa nel bucket corrente. Pinniamo il
    # fallback silenzioso così una regressione (es. rimozione del rescue) diventa rossa in CI.
    it "stringa non parsabile ('2026-13-45') ripiega su Time.current in silenzio (nessun crash)" do
      travel_to(Time.utc(2026, 6, 1, 12)) do
        n = described_class.call(payload: {
          "kind" => "slow_query", "sql" => "SELECT 1", "duration_ms" => 5,
          "occurred_at" => "2026-13-45"
        })
        expect(n.occurred_at).to be_within(1).of(Time.current)
      end
    end

    it "assente → ripiega su Time.current (ramo else → nil)" do
      travel_to(Time.utc(2026, 6, 1, 12)) do
        n = described_class.call(payload: { "kind" => "slow_query", "sql" => "SELECT 1", "duration_ms" => 5 })
        expect(n.occurred_at).to be_within(1).of(Time.current)
      end
    end
  end

  describe "hardening 2026-07-09 (audit metriche)" do
    it "payload non-Hash → kind nil, nessun crash" do
      n = described_class.call(payload: 42)
      expect(n.kind).to be_nil
      expect(n.title).to eq("metric")
    end

    it "strippa i null byte da sql (evita crash INSERT Postgres)" do
      nul = 0.chr
      n = described_class.call(payload: { "kind" => "slow_query", "sql" => "SELECT#{nul} 1", "duration_ms" => 5 })
      expect(n.title).not_to include(nul)
      expect(n.payload["sql"]).not_to include(nul)
    end

    it "clampa duration_ms negativo a 0 (non avvelena min/avg del gruppo)" do
      n = described_class.call(payload: { "kind" => "slow_query", "sql" => "SELECT 1", "duration_ms" => -40 })
      expect(n.duration_ms).to eq(0.0)
    end

    it "templatize maschera i literal stringa (PII email/token) nel title/signature" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "duration_ms" => 9,
        "sql" => "SELECT * FROM users WHERE email = 'a@b.com' AND status = 5"
      })
      expect(n.title).to include("<str>")
      expect(n.title).not_to include("a@b.com")
    end
  end

  # CYRA-40: il payload persistito era conservato raw (a differenza degli eventi errore) → segreti in
  # chiaro at-rest. Scrub server-side per parità con Errors::Ingest::Normalize.
  describe "scrub PII del payload persistito (CYRA-40)" do
    it "templatizza lo SQL nel payload: i literal-stringa col token spariscono" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "duration_ms" => 9,
        "sql" => "SELECT * FROM users WHERE token = 'abc123secret' AND id = 5"
      })
      expect(n.payload["sql"]).not_to include("abc123secret")
      expect(n.payload["sql"]).to include("<str>")
    end

    it "maschera anche l'email nei literal SQL" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "duration_ms" => 9,
        "sql" => "SELECT * FROM users WHERE email = 'a@b.com'"
      })
      expect(n.payload["sql"]).not_to include("a@b.com")
    end

    it "templatizza anche i valori NUMERICI sensibili nello SQL (non solo i literal tra apici)" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "duration_ms" => 9,
        "sql" => "SELECT * FROM people WHERE ssn = 123456789"
      })
      expect(n.payload["sql"]).not_to include("123456789")
      expect(n.payload["sql"]).to include("<n>")
    end

    it "maschera i literal dollar-quoted PostgreSQL ($$…$$ / $tag$…$tag$)" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "duration_ms" => 9,
        "sql" => "SELECT * FROM users WHERE token = $$abc123secret$$ AND key = $x$topsecret$x$"
      })
      expect(n.payload["sql"]).not_to include("abc123secret")
      expect(n.payload["sql"]).not_to include("topsecret")
    end

    it "strippa la query (api_key) da http_url tenendo scheme+host+path" do
      n = described_class.call(payload: {
        "kind" => "performance_issue", "subtype" => "slow_external_http",
        "http_host" => "api.stripe.com", "duration_ms" => 900,
        "http_url" => "https://api.stripe.com/v1/charges?api_key=sk_live_secret123"
      })
      expect(n.payload["http_url"]).to eq("https://api.stripe.com/v1/charges")
      expect(n.payload["http_url"]).not_to include("sk_live_secret123")
    end

    it "strippa la query anche da http_path" do
      n = described_class.call(payload: {
        "kind" => "performance_issue", "subtype" => "repeated_http",
        "http_host" => "api.x.it", "duration_ms" => 300,
        "http_path" => "/v1/items?token=zzz999"
      })
      expect(n.payload["http_path"]).to eq("/v1/items")
      expect(n.payload["http_path"]).not_to include("zzz999")
    end

    it "redige i valori delle chiavi sensibili (denylist ricorsiva Hash E Array)" do
      n = described_class.call(payload: {
        "kind" => "slow_method", "label" => "Checkout#charge", "duration_ms" => 50,
        "context" => {
          "api_key" => "sk_secret",
          "nested" => [ { "email" => "user@corp.com" }, { "safe" => "ok" } ]
        }
      })
      expect(n.payload["context"]["api_key"]).to eq("[FILTERED]")
      expect(n.payload["context"]["nested"][0]["email"]).to eq("[FILTERED]")
      expect(n.payload["context"]["nested"][1]["safe"]).to eq("ok")
    end

    it "redige le chiavi sensibili anche in camelCase (authToken/userEmail)" do
      n = described_class.call(payload: {
        "kind" => "slow_method", "label" => "X#y", "duration_ms" => 5,
        "context" => { "authToken" => "t", "userEmail" => "u@x.it" }
      })
      expect(n.payload["context"]["authToken"]).to eq("[FILTERED]")
      expect(n.payload["context"]["userEmail"]).to eq("[FILTERED]")
    end

    it "NON redige i campi tecnici che contengono per caso un termine (span_id, mapping, cache_key)" do
      n = described_class.call(payload: {
        "kind" => "performance_issue", "subtype" => "slow_request", "route" => "X#i", "duration_ms" => 50,
        "span_id" => "abc-123", "context" => { "mapping" => "m", "cache_key" => "users/1" }
      })
      expect(n.payload["span_id"]).to eq("abc-123") # `pan` è sottostringa ma non un segmento
      expect(n.payload["context"]["mapping"]).to eq("m") # `pin`
      expect(n.payload["context"]["cache_key"]).to eq("users/1") # `key` da solo non è sensibile
    end

    it "è lossless per i valori non sensibili (db_system, query_count, cached restano)" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "sql" => "SELECT 1", "duration_ms" => 5,
        "db_system" => "postgresql", "query_count" => 3, "cached" => false
      })
      expect(n.payload["db_system"]).to eq("postgresql")
      expect(n.payload["query_count"]).to eq(3)
      expect(n.payload["cached"]).to be(false)
    end

    it "non muta l'input né altri campi derivati (signature resta templatizzata)" do
      n = described_class.call(payload: {
        "kind" => "slow_query", "duration_ms" => 9,
        "sql" => "SELECT * FROM users WHERE token = 'abc123secret'"
      })
      expect(n.signature).to include("<str>") # la signature usa lo SQL raw templatizzato, non lo scrub
      expect(n.signature).not_to include("abc123secret")
    end
  end
end
