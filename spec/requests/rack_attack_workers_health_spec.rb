# frozen_string_literal: true

require "rails_helper"

# CYRA-1273: /up/workers è pubblico e ogni chiamata interroga la coda dei job. Senza freno uno script
# in ciclo lo chiamava quanto voleva. rack-attack è disabilitato nei test (spec/support/rack_attack.rb):
# il block si prova da solo, come rack_attack_share_analytics_spec, e il confine dal vivo con un
# memory store, perché il null_store dei test non fa avanzare il contatore.
RSpec.describe "Rack::Attack — /up/workers", type: :request do
  def attack_request(path, method: "GET", ip: "203.0.113.7")
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip))
  end

  let(:throttle) { Rack::Attack.throttles.fetch("workers_health/ip") }

  describe "throttle workers_health/ip" do
    it "matcha il GET /up/workers per IP" do
      expect(throttle.block.call(attack_request("/up/workers"))).to eq("203.0.113.7")
    end

    # Rails serve HEAD con l'azione della rotta GET: stesse domande alla coda, stesso freno.
    it "matcha anche l'HEAD /up/workers per IP" do
      expect(throttle.block.call(attack_request("/up/workers", method: "HEAD"))).to eq("203.0.113.7")
    end

    it "NON matcha /up, che resta liveness pura senza freno" do
      expect(throttle.block.call(attack_request("/up"))).to be_nil
    end

    it "NON matcha gli altri controlli pubblici" do
      expect(throttle.block.call(attack_request("/up/recurring"))).to be_nil
      expect(throttle.block.call(attack_request("/version"))).to be_nil
    end

    it "è gemello di public_status/ip: 60 richieste al minuto" do
      expect(throttle.limit).to eq(60)
      expect(throttle.period).to eq(60)
    end
  end

  describe "dal vivo" do
    around do |example|
      original = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      Rack::Attack.enabled = true
      freeze_time { example.run } # tutte le chiamate nello stesso minuto: la finestra non si azzera a metà
    ensure
      Rack::Attack.enabled = false
      Rack::Attack.cache.store = original
    end

    # Più richieste per example: le stesse query a ogni richiesta sono il controllo ripetuto, non un
    # N+1 di produzione — fuori dallo scan.
    it "lascia passare 60 chiamate in un minuto e frena la 61a senza contare la coda" do
      allow_n_plus_one do
        60.times do
          get "/up/workers"
          expect(response).not_to have_http_status(:too_many_requests)
        end
      end

      expect(Ops::QueueThroughput).not_to receive(:ready_count)
      expect(Ops::QueueThroughput).not_to receive(:stalled_lanes)

      get "/up/workers"

      expect(response).to have_http_status(:too_many_requests)
    end

    it "frena anche chi passa a HEAD: le chiamate GET e HEAD contano insieme" do
      allow_n_plus_one do
        30.times { get "/up/workers" }
        30.times do
          head "/up/workers"
          expect(response).not_to have_http_status(:too_many_requests)
        end
      end

      expect(Ops::QueueThroughput).not_to receive(:ready_count)
      expect(Ops::QueueThroughput).not_to receive(:stalled_lanes)

      head "/up/workers"

      expect(response).to have_http_status(:too_many_requests)
    end

    it "i 3 tentativi ravvicinati del guardiano esterno non vengono mai frenati" do
      SolidQueue::Process.create!(kind: "Worker", name: "worker-1", pid: 1, last_heartbeat_at: Time.current)

      allow_n_plus_one do
        3.times do
          get "/up/workers"
          expect(response).to have_http_status(:ok)
        end
      end
    end
  end
end
