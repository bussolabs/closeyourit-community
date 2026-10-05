# frozen_string_literal: true

require "rails_helper"

# CYRA-247: il link pubblico alle statistiche (/share/analytics/:slug) non aveva alcun freno. Ogni
# apertura ricalcola da zero decine di aggregati pesanti (Analytics::Snapshot) sul DB condiviso col
# monitoring, e il POST che verifica la password (bcrypt) era brute-forzabile a oltranza. Servono due
# throttle: uno per IP sulle aperture (GET), uno molto più stretto per SLUG sui tentativi password
# (POST). rack-attack è disabilitato nei test (spec/support/rack_attack.rb) → si verificano invocando
# direttamente il block del throttle, come rack_attack_auth_spec / rack_attack_ingest_spec.
RSpec.describe "Rack::Attack — statistiche condivise", type: :request do
  def attack_request(path, method: "GET", ip: "203.0.113.7")
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip))
  end

  let(:slug) { "a1b2c3d4e5" }

  describe "throttle share_analytics/ip (aperture del link)" do
    let(:throttle) { Rack::Attack.throttles.fetch("share_analytics/ip") }

    it "matcha il GET /share/analytics/:slug per IP" do
      expect(throttle.block.call(attack_request("/share/analytics/#{slug}"))).to eq("203.0.113.7")
    end

    it "NON matcha il POST (coperto dal throttle password per-slug)" do
      expect(throttle.block.call(attack_request("/share/analytics/#{slug}", method: "POST"))).to be_nil
    end

    it "NON matcha path fuori dallo share analytics" do
      expect(throttle.block.call(attack_request("/status/acme/web/prod"))).to be_nil
    end

    it "è gemella di public_status/ip: 60 richieste al minuto" do
      expect(throttle.limit).to eq(60)
      expect(throttle.period).to eq(60)
    end
  end

  describe "throttle share_analytics_password/slug (tentativi password)" do
    let(:throttle) { Rack::Attack.throttles.fetch("share_analytics_password/slug") }

    it "matcha il POST /share/analytics/:slug con chiave = slug" do
      expect(throttle.block.call(attack_request("/share/analytics/#{slug}", method: "POST"))).to eq(slug)
    end

    it "matcha anche col trailing slash finale" do
      expect(throttle.block.call(attack_request("/share/analytics/#{slug}/", method: "POST"))).to eq(slug)
    end

    it "normalizza lo slug URL-encoded sulla stessa chiave, così il limite non si aggira variando la codifica (CYRA-247)" do
      plain = throttle.block.call(attack_request("/share/analytics/#{slug}", method: "POST"))
      encoded = throttle.block.call(attack_request("/share/analytics/%61#{slug[1..]}", method: "POST")) # %61 == "a"

      expect(encoded).to eq(slug)
      expect(encoded).to eq(plain)
    end

    it "NON matcha il GET (solo il POST verifica la password)" do
      expect(throttle.block.call(attack_request("/share/analytics/#{slug}"))).to be_nil
    end

    it "NON matcha path diversi né lo share senza slug" do
      expect(throttle.block.call(attack_request("/share/analytics/", method: "POST"))).to be_nil
      expect(throttle.block.call(attack_request("/login", method: "POST"))).to be_nil
    end

    it "è molto più stretto delle aperture: 10 tentativi ogni 15 minuti" do
      expect(throttle.limit).to eq(10)
      expect(throttle.period).to eq(15.minutes.to_i)
    end
  end

  # Confine del limite per-slug: dimostra che i tentativi in eccesso vengono davvero rifiutati
  # (DoD: "bloccato dopo pochi tentativi"). rack-attack conta su una cache condivisa (in test un
  # null_store che non incrementa): serve un memory store perché il contatore avanzi davvero.
  describe "confine dei tentativi password (X / X+1)" do
    let(:throttle) { Rack::Attack.throttles.fetch("share_analytics_password/slug") }

    around do |example|
      original = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
      Rack::Attack.cache.store = original
    end

    it "consente fino al limite e blocca appena lo supera, per lo stesso link" do
      request = attack_request("/share/analytics/#{slug}", method: "POST")
      (throttle.limit - 1).times { throttle.matched_by?(request) } # porta il contatore a X-1

      expect(throttle.matched_by?(request)).to be(false) # X: raggiunge il limite, ancora consentito
      expect(throttle.matched_by?(request)).to be(true)  # X+1: supera il limite, throttled
    end
  end
end
