# frozen_string_literal: true

require "rails_helper"

# Compat SDK Sentry: il throttle per-progetto deve coprire ANCHE il trailing slash
# (sentry-ruby posta sempre su /api/<id>/envelope/), e il 429 deve esporre Retry-After.
RSpec.describe "Rack::Attack — ingest", type: :request do
  def attack_request(path, method: "POST")
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method))
  end

  describe "discriminatore ingest/project" do
    let(:throttle) { Rack::Attack.throttles.fetch("ingest/project") }
    let(:project_id) { "550e8400-e29b-41d4-a716-446655440000" }

    it "matcha envelope e store senza slash finale" do
      expect(throttle.block.call(attack_request("/api/#{project_id}/envelope"))).to eq(project_id)
      expect(throttle.block.call(attack_request("/api/#{project_id}/store"))).to eq(project_id)
    end

    it "matcha il trailing slash usato dagli SDK Sentry ufficiali" do
      expect(throttle.block.call(attack_request("/api/#{project_id}/envelope/"))).to eq(project_id)
      expect(throttle.block.call(attack_request("/api/#{project_id}/store/"))).to eq(project_id)
    end

    it "non matcha GET né path diversi" do
      expect(throttle.block.call(attack_request("/api/#{project_id}/envelope", method: "GET"))).to be_nil
      expect(throttle.block.call(attack_request("/api/v1/projects/#{project_id}/metrics"))).to be_nil
    end
  end

  # CYRA-251 — le regex per-progetto matchavano solo il path nudo (envelope/store) o le sole estensioni
  # minuscole (canali v1, vecchio (?:\.[a-z]+)?): aggiungere .json / .JSON / .J1 all'indirizzo azzerava
  # il limite senza lasciare traccia. Il throttle deve valere identico su OGNI forma dell'indirizzo.
  describe "l'estensione di formato non aggira il throttle per-progetto" do
    let(:project_id) { "550e8400-e29b-41d4-a716-446655440000" }

    # throttle per-progetto => template del path del canale (POST). Ogni forma con estensione deve
    # cadere sulla stessa chiave (il project_id) del path nudo.
    {
      "ingest/project"    => "/api/%<id>s/envelope",
      "events/project"    => "/api/v1/projects/%<id>s/events",
      "metrics/project"   => "/api/v1/projects/%<id>s/metrics",
      "logs/project"      => "/api/v1/projects/%<id>s/logs",
      "pageviews/project" => "/api/v1/projects/%<id>s/pageviews",
      "replays/project"   => "/api/v1/projects/%<id>s/replays",
      "helpdesk/project"  => "/api/v1/projects/%<id>s/helpdesk_requests"
    }.each do |name, template|
      context "canale #{name}" do
        let(:throttle) { Rack::Attack.throttles.fetch(name) }
        let(:base) { format(template, id: project_id) }

        it "matcha con estensione minuscola, MAIUSCOLA e alfanumerica (.json .JSON .J1 .Xml)" do
          %w[.json .JSON .J1 .Xml].each do |ext|
            expect(throttle.block.call(attack_request("#{base}#{ext}"))).to eq(project_id)
          end
        end

        it "matcha con estensione seguita dal trailing slash" do
          expect(throttle.block.call(attack_request("#{base}.json/"))).to eq(project_id)
        end

        it "resta ancorato: un segmento extra dopo l'estensione non matcha (nessun over-match)" do
          expect(throttle.block.call(attack_request("#{base}.json/extra"))).to be_nil
        end

        it "normalizza il percent-encoding del project_id: la stessa risorsa cade sulla stessa chiave (CYRA-247)" do
          # Rails instrada /api/%35%35%30e…/envelope allo stesso progetto, ma req.path resta URL-encoded:
          # senza decodificare, la variante encoded avrebbe un contatore proprio e aggirerebbe il limite.
          encoded_path = base.sub(project_id, project_id.sub("550", "%35%35%30")) # 550 -> %35%35%30
          expect(throttle.block.call(attack_request(encoded_path))).to eq(project_id)
        end
      end
    end

    context "conteggio condiviso tra le forme (il limite scatta comunque sia scritto l'indirizzo)" do
      let(:throttle) { Rack::Attack.throttles.fetch("ingest/project") }

      around do |example|
        original = Rack::Attack.cache.store
        Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
        example.run
        Rack::Attack.cache.store = original
      end

      def request_for(path)
        Rack::Attack::Request.new(
          Rack::MockRequest.env_for(path, method: "POST", "REMOTE_ADDR" => "198.51.100.11")
        )
      end

      it "somma path nudo, .json, .JSON, trailing slash e .J1 sullo stesso contatore per-progetto" do
        base = "/api/#{project_id}/envelope"
        forms = [ "", ".json", ".JSON", "/", ".J1" ]
        req = ->(i) { request_for("#{base}#{forms[i % forms.size]}") }

        # Il contatore vive in una finestra allineata all'orologio: se la prova scavalca il bordo del
        # periodo il conteggio riparte da zero e l'ultima richiesta non risulta oltre il limite. Fermiamo
        # il tempo appena dentro un periodo, così tutte le richieste cadono nella stessa finestra.
        period = throttle.period.to_i
        travel_to Time.zone.at(Time.current.to_i / period * period + 1)

        # `limit - 1` richieste alternando le cinque forme: se ognuna avesse un contatore proprio non
        # scatterebbe mai. Portano il contatore CONDIVISO a X-1.
        (throttle.limit - 1).times { |i| throttle.matched_by?(req.call(i)) }

        expect(throttle.matched_by?(req.call(throttle.limit - 1))).to be(false) # X: al limite, consentito
        expect(throttle.matched_by?(req.call(throttle.limit))).to be(true)      # X+1: oltre → throttled
      end
    end
  end

  describe "throttled_responder" do
    it "risponde 429 con Retry-After calcolato dalla finestra" do
      env = Rack::MockRequest.env_for("/api/x/envelope")
      env["rack.attack.match_data"] = { period: 60, epoch_time: Time.current.to_i }

      status, headers, body = Rack::Attack.throttled_responder.call(Rack::Attack::Request.new(env))

      expect(status).to eq(429)
      expect(headers["Retry-After"].to_i).to be_between(1, 60)
      expect(JSON.parse(body.first).dig("error", "code")).to eq("R429-SYSTEM-001")
    end

    it "senza match_data ripiega su 60 secondi" do
      status, headers, = Rack::Attack.throttled_responder.call(Rack::Attack::Request.new(Rack::MockRequest.env_for("/x")))

      expect(status).to eq(429)
      expect(headers["Retry-After"]).to eq("60")
    end
  end

  # CYRA-109 — Definition of Done: quote e rate limit per progetto E per IP applicati sul public ingest.
  describe "quote applicate sul public ingest (per progetto e per IP)" do
    it "ha una quota PER-PROGETTO su ogni canale di ingest" do
      {
        "ingest/project" => 600,     # /api/:id/{envelope,store} (route Sentry drop-in)
        "events/project" => 1200,    # /api/v1/projects/:id/events
        "metrics/project" => 1200,   # /api/v1/projects/:id/metrics
        "logs/project" => 1200,      # /api/v1/projects/:id/logs
        "pageviews/project" => 600,  # /api/v1/projects/:id/pageviews
        "replays/project" => 600     # /api/v1/projects/:id/replays
      }.each do |name, limit|
        throttle = Rack::Attack.throttles.fetch(name)
        expect(throttle.limit).to eq(limit)
        expect(throttle.period).to eq(60)
      end
    end

    it "ha una quota PER-IP che copre gli endpoint di ingest (api/ip, 300/min)" do
      throttle = Rack::Attack.throttles.fetch("api/ip")
      ip_request = Rack::Attack::Request.new(
        Rack::MockRequest.env_for("/api/v1/projects/abc/events", method: "POST", "REMOTE_ADDR" => "198.51.100.4")
      )
      envelope_request = Rack::Attack::Request.new(
        Rack::MockRequest.env_for("/api/abc/envelope", method: "POST", "REMOTE_ADDR" => "198.51.100.4")
      )

      expect(throttle.limit).to eq(300)
      expect(throttle.block.call(ip_request)).to eq("198.51.100.4")
      expect(throttle.block.call(envelope_request)).to eq("198.51.100.4")
    end
  end

  # Confine del rate limit per-progetto: sotto il limite passa, al limite passa, appena sopra blocca.
  describe "confine della quota per-progetto (X-1 / X / X+1)" do
    let(:throttle) { Rack::Attack.throttles.fetch("ingest/project") }
    let(:project_id) { "550e8400-e29b-41d4-a716-446655440000" }

    around do |example|
      # rack-attack usa una cache condivisa (di default Rails.cache, in test un null_store che non
      # conta): serve un memory store perché il conteggio incrementi davvero.
      original = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
      Rack::Attack.cache.store = original
    end

    def ingest_request
      Rack::Attack::Request.new(
        Rack::MockRequest.env_for("/api/#{project_id}/envelope", method: "POST", "REMOTE_ADDR" => "198.51.100.7")
      )
    end

    it "consente fino al limite e throttla appena lo supera" do
      request = ingest_request
      (throttle.limit - 1).times { throttle.matched_by?(request) } # porta il contatore a X-1

      expect(throttle.matched_by?(request)).to be(false) # X: raggiunge il limite, ancora consentito
      expect(throttle.matched_by?(request)).to be(true)  # X+1: supera il limite, throttled
    end
  end

  # DoD: i limiti devono essere OSSERVABILI. Ogni throttle scattato emette un log warn (che il
  # self-monitoring closeyourit-ruby cattura → i limiti diventano visibili nel monitoring).
  describe "osservabilità dei limiti (log warn)" do
    it "logga a warn quando un throttle scatta, citando la regola e il discriminatore" do
      env = Rack::MockRequest.env_for("/api/v1/projects/abc/events", method: "POST", "REMOTE_ADDR" => "198.51.100.9")
      env["rack.attack.matched"] = "events/project"
      env["rack.attack.match_discriminator"] = "abc"
      env["rack.attack.match_type"] = :throttle
      request = Rack::Attack::Request.new(env)

      expect(Rails.logger).to receive(:warn).with(/rack-attack.*events\/project.*abc/)

      ActiveSupport::Notifications.instrument("throttle.rack_attack", request: request)
    end

    # L'esempio sopra pubblica la notifica A MANO: verifica il formato del messaggio, non che
    # rack-attack la emetta davvero né con quale payload. Se la gem cambiasse la chiave del payload
    # (oggi `request:`) o il nome delle annotazioni in env, quell'esempio resterebbe verde mentre in
    # produzione nessun limite finirebbe più nei log: l'osservabilità della Definition of Done
    # sparirebbe in silenzio, che è esattamente il modo in cui una difesa smette di esistere senza
    # che nessuno se ne accorga. Qui il warn arriva dal percorso REALE — è rack-attack a contare, a
    # superare il limite, ad annotare la richiesta e a instrumentare.
    context "percorso reale (il throttle scatta davvero)" do
      let(:throttle) { Rack::Attack.throttles.fetch("ingest/project") }
      let(:project_id) { "550e8400-e29b-41d4-a716-446655440000" }

      around do |example|
        original = Rack::Attack.cache.store
        Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
        example.run
        Rack::Attack.cache.store = original
      end

      def ingest_request
        Rack::Attack::Request.new(
          Rack::MockRequest.env_for("/api/#{project_id}/envelope", method: "POST", "REMOTE_ADDR" => "198.51.100.12")
        )
      end

      it "logga il warn solo quando la quota per-progetto viene superata, citando regola e progetto" do
        request = ingest_request
        # Finestra allineata all'orologio: fermiamo il tempo appena dentro un periodo, altrimenti il
        # conteggio può ripartire a metà prova e l'ultima richiesta non risulterebbe oltre il limite.
        period = throttle.period.to_i
        travel_to Time.zone.at(Time.current.to_i / period * period + 1)
        allow(Rails.logger).to receive(:warn)

        throttle.limit.times { throttle.matched_by?(request) } # fino al limite: consentito
        expect(Rails.logger).not_to have_received(:warn)       # sotto quota nessun rumore nei log

        throttle.matched_by?(request) # X+1: supera → rack-attack instrumenta sul serio

        expect(Rails.logger).to have_received(:warn)
          .with(%r{rack-attack.*rule=ingest/project.*discriminator=#{project_id}}).once
      end
    end
  end
end

# CYRA-940 — people write help desk requests: the limits sit far below telemetry.
RSpec.describe "Rack::Attack — help desk requests", type: :request do
  def attack_request(path, method: "POST", ip: "203.0.113.9")
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip))
  end

  let(:path) { "/api/v1/projects/550e8400-e29b-41d4-a716-446655440000/helpdesk_requests" }

  it "allows far fewer requests than telemetry, per project and per address" do
    project = Rack::Attack.throttles.fetch("helpdesk/project")
    address = Rack::Attack.throttles.fetch("helpdesk/ip")

    expect(project.limit).to be <= 30
    expect(address.limit).to be <= 5
    expect(project.limit).to be < Rack::Attack.throttles.fetch("pageviews/project").limit
  end

  it "counts a visitor by address, only on this door" do
    throttle = Rack::Attack.throttles.fetch("helpdesk/ip")

    expect(throttle.block.call(attack_request(path))).to eq("203.0.113.9")
    expect(throttle.block.call(attack_request(path, method: "GET"))).to be_nil
    expect(throttle.block.call(attack_request(path.sub("helpdesk_requests", "pageviews")))).to be_nil
  end
end
