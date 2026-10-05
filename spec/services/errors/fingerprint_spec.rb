# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Fingerprint, type: :service do
  def fp(payload) = described_class.call(payload: payload)

  def exception_event(type:, value:, frames:)
    { "exception" => { "values" => [ { "type" => type, "value" => value,
      "stacktrace" => { "frames" => frames } } ] } }
  end

  describe "determinismo" do
    it "stesso payload → stesso fingerprint" do
      payload = exception_event(type: "RuntimeError", value: "boom",
        frames: [ { "function" => "call", "module" => "App", "in_app" => true } ])
      expect(fp(payload)).to eq(fp(payload))
    end

    it "ritorna una stringa hex sha256 (64 char)" do
      expect(fp({ "message" => "hi" })).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe "branch exception (type + culprit, NON il value)" do
    it "stesso type+culprit ma value diverso (ID variabile) → STESSO fingerprint" do
      frames = [ { "function" => "find", "module" => "App::Users", "in_app" => true } ]
      a = exception_event(type: "ActiveRecord::RecordNotFound", value: "id=1", frames: frames)
      b = exception_event(type: "ActiveRecord::RecordNotFound", value: "id=99999", frames: frames)
      expect(fp(a)).to eq(fp(b))
    end

    it "type diverso → fingerprint diverso" do
      frames = [ { "function" => "call", "module" => "App", "in_app" => true } ]
      a = exception_event(type: "RuntimeError", value: "x", frames: frames)
      b = exception_event(type: "TypeError", value: "x", frames: frames)
      expect(fp(a)).not_to eq(fp(b))
    end

    it "culprit (funzione) diverso → fingerprint diverso" do
      a = exception_event(type: "E", value: "x",
        frames: [ { "function" => "foo", "module" => "App", "in_app" => true } ])
      b = exception_event(type: "E", value: "x",
        frames: [ { "function" => "bar", "module" => "App", "in_app" => true } ])
      expect(fp(a)).not_to eq(fp(b))
    end

    it "preferisce l'ultimo frame in_app a frame di libreria successivi" do
      a = exception_event(type: "E", value: "x", frames: [
        { "function" => "app_call", "module" => "App", "in_app" => true },
        { "function" => "lib_call", "module" => "Gem", "in_app" => false }
      ])
      b = exception_event(type: "E", value: "x", frames: [
        { "function" => "app_call", "module" => "App", "in_app" => true },
        { "function" => "other_lib", "module" => "Gem2", "in_app" => false }
      ])
      expect(fp(a)).to eq(fp(b)) # il frame in_app domina, i frame di libreria non spostano il gruppo
    end

    it "includes the cause chain without changing single-exception grouping" do
      chained = { "exception" => { "values" => [
        { "type" => "OuterError", "value" => "wrap",
          "stacktrace" => { "frames" => [ { "function" => "a", "module" => "App", "in_app" => true } ] } },
        { "type" => "InnerError", "value" => "root",
          "stacktrace" => { "frames" => [ { "function" => "b", "module" => "App", "in_app" => true } ] } }
      ] } }
      only_inner = exception_event(type: "InnerError", value: "root",
        frames: [ { "function" => "b", "module" => "App", "in_app" => true } ])
      expect(fp(chained)).not_to eq(fp(only_inner))
    end
  end

  describe "branch message (templato)" do
    it "numeri diversi → STESSO fingerprint (templatizzati)" do
      expect(fp({ "message" => "User 1 not found" })).to eq(fp({ "message" => "User 9999 not found" }))
    end

    it "uuid templatizzato" do
      a = { "message" => "missing 550e8400-e29b-41d4-a716-446655440000" }
      b = { "message" => "missing 999e8400-e29b-41d4-a716-446655440abc" }
      expect(fp(a)).to eq(fp(b))
    end

    it "testo diverso → fingerprint diverso" do
      expect(fp({ "message" => "Disk full" })).not_to eq(fp({ "message" => "Network down" }))
    end

    it "message come hash { formatted } è supportato" do
      expect(fp({ "message" => { "formatted" => "boom" } })).to eq(fp({ "message" => "boom" }))
    end
  end

  describe "fingerprint client" do
    it "fingerprint custom → indipendente da exception/message" do
      a = exception_event(type: "E", value: "x", frames: []).merge("fingerprint" => [ "payment-flow" ])
      b = { "message" => "totally different", "fingerprint" => [ "payment-flow" ] }
      expect(fp(a)).to eq(fp(b))
    end

    it "fingerprint custom diverso → gruppo diverso" do
      a = { "message" => "x", "fingerprint" => [ "key-a" ] }
      b = { "message" => "x", "fingerprint" => [ "key-b" ] }
      expect(fp(a)).not_to eq(fp(b))
    end

    it "['{{ default }}'] equivale all'algoritmo di default" do
      base = exception_event(type: "E", value: "x",
        frames: [ { "function" => "f", "module" => "App", "in_app" => true } ])
      with_default = base.merge("fingerprint" => [ "{{ default }}" ])
      expect(fp(with_default)).to eq(fp(base))
    end

    it "'{{ default }}' + token custom combina (≠ default puro, ≠ custom puro)" do
      base = exception_event(type: "E", value: "x",
        frames: [ { "function" => "f", "module" => "App", "in_app" => true } ])
      combined = base.merge("fingerprint" => [ "{{ default }}", "tenant-42" ])
      custom_only = { "fingerprint" => [ "tenant-42" ] }
      expect(fp(combined)).not_to eq(fp(base))
      expect(fp(combined)).not_to eq(fp(custom_only))
    end
  end

  describe "regressione grouping: i campi arricchiti NON spostano il fingerprint" do
    it "stesso evento con/senza request/user/tags/breadcrumbs → STESSO fingerprint" do
      base = exception_event(type: "RuntimeError", value: "boom",
        frames: [ { "function" => "call", "module" => "App", "in_app" => true } ])
      enriched = base.merge(
        "user" => { "id" => "9" },
        "request" => { "method" => "GET", "url" => "https://x/y" },
        "tags" => { "area" => "checkout" },
        "breadcrumbs" => { "values" => [ { "category" => "query", "message" => "SELECT ?" } ] }
      )
      expect(fp(enriched)).to eq(fp(base))
    end
  end

  describe "fallback ed edge" do
    it "payload vuoto → fingerprint stabile (transaction unknown)" do
      expect(fp({})).to eq(fp({}))
    end

    it "solo transaction → usa la transaction" do
      expect(fp({ "transaction" => "GET /a" })).not_to eq(fp({ "transaction" => "GET /b" }))
    end

    it "exception senza frames → type soltanto, ancora stabile" do
      a = { "exception" => { "values" => [ { "type" => "E", "value" => "1" } ] } }
      b = { "exception" => { "values" => [ { "type" => "E", "value" => "2" } ] } }
      expect(fp(a)).to eq(fp(b))
    end
  end
end
