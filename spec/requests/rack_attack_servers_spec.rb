# frozen_string_literal: true

require "rails_helper"

# CYRA-775 — gli agent di una flotta escono quasi sempre dallo STESSO indirizzo (un solo gateway di
# uscita), e le loro richieste cadevano nel contatore per indirizzo condiviso con tutto il resto di
# /api: bastava che le applicazioni monitorate mandassero errori, log e misure dallo stesso posto
# perché il backend rispondesse «troppe richieste» anche alle sonde. Da lì il sistema leggeva il
# silenzio come «la macchina è caduta».
#
# rack-attack è disattivato in tutta la suite (spec/support/rack_attack.rb): come gli altri spec dei
# throttle, qui si invoca direttamente il block della regola.
RSpec.describe "Rack::Attack — agent di server monitoring", type: :request do
  let(:throttle) { Rack::Attack.throttles.fetch("servers_ingest/agent") }
  let(:api_throttle) { Rack::Attack.throttles.fetch("api/ip") }
  let(:token) { "cyi_s_unsegretoqualsiasi" }
  let(:action_id) { "5b1f0c5e-0000-4000-8000-000000000001" }

  def attack_request(path, method: "POST", bearer: token, ip: "203.0.113.7")
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip)
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    Rack::Attack::Request.new(env)
  end

  describe "cosa entra nel conteggio" do
    it "il push delle misure, la presa in carico di un'azione e il suo esito" do
      expect(throttle.block.call(attack_request("/api/v1/servers/samples"))).to be_present
      expect(throttle.block.call(attack_request("/api/v1/servers/action_claims"))).to be_present
      expect(throttle.block.call(attack_request("/api/v1/servers/actions/#{action_id}", method: "PATCH")))
        .to be_present
    end

    # CYRA-251, stessa trappola degli ingest per-progetto: le rotte instradano anche con estensione,
    # quindi cinque caratteri in coda non devono aprire un contatore nuovo.
    it "l'estensione di formato e lo slash finale non aprono un contatore proprio" do
      nudo = throttle.block.call(attack_request("/api/v1/servers/samples"))

      %w[.json .JSON .J1 .Xml].each do |ext|
        expect(throttle.block.call(attack_request("/api/v1/servers/samples#{ext}"))).to eq(nudo)
      end
      expect(throttle.block.call(attack_request("/api/v1/servers/samples.json/"))).to eq(nudo)
    end

    it "resta ancorato: un segmento in più dopo l'estensione non matcha" do
      expect(throttle.block.call(attack_request("/api/v1/servers/samples.json/extra"))).to be_nil
    end

    it "le letture non consumano nulla: si conta chi scrive" do
      expect(throttle.block.call(attack_request("/api/v1/servers/samples", method: "GET"))).to be_nil
    end
  end

  describe "la chiave del conteggio" do
    it "è il digest del token, mai il segreto in chiaro né il digest intero" do
      key = throttle.block.call(attack_request("/api/v1/servers/samples"))

      expect(key).to be_present
      expect(key).not_to include(token)
      expect(key).not_to eq(Digest::SHA256.hexdigest(token))
      expect(Digest::SHA256.hexdigest(token)).to start_with(key)
    end

    # Il cuore del ticket: la credenziale è per macchina, l'indirizzo di uscita è di tutta la flotta.
    it "è la stessa credenziale su tutti i suoi indirizzi, e diversa fra due macchine sullo stesso" do
      da_un_indirizzo = throttle.block.call(attack_request("/api/v1/servers/samples", ip: "203.0.113.1"))
      da_un_altro = throttle.block.call(attack_request("/api/v1/servers/samples", ip: "198.51.100.9"))
      altra_macchina = throttle.block.call(attack_request("/api/v1/servers/samples", bearer: "cyi_s_altra"))

      expect(da_un_altro).to eq(da_un_indirizzo)
      expect(altra_macchina).not_to eq(da_un_indirizzo)
    end

    it "senza Bearer non matcha: a chi non si presenta risponde l'autenticazione" do
      expect(throttle.block.call(attack_request("/api/v1/servers/samples", bearer: nil))).to be_nil
    end
  end

  # La causa del guasto: il contatore per indirizzo di tutta /api (300 al minuto) è condiviso con
  # l'ingest di errori, log, misure e visite di OGNI applicazione monitorata. Le sonde ci stavano
  # dentro, e venivano rifiutate per il consumo altrui.
  describe "la quota degli agent non è più quella di tutto il resto di /api" do
    it "le scritture di una sonda autenticata restano fuori dal contatore per indirizzo di /api" do
      expect(api_throttle.block.call(attack_request("/api/v1/servers/samples"))).to be_nil
      expect(api_throttle.block.call(attack_request("/api/v1/servers/action_claims"))).to be_nil
      expect(api_throttle.block.call(attack_request("/api/v1/servers/actions/#{action_id}", method: "PATCH")))
        .to be_nil
    end

    it "il resto di /api continua a contare per indirizzo" do
      expect(api_throttle.block.call(attack_request("/api/v1/projects/abc/events"))).to eq("203.0.113.7")
    end

    # L'uscita da /api vale solo per ciò che il tetto dedicato prende in carico davvero: un buco per
    # prefisso avrebbe lasciato senza alcun freno il traffico anonimo verso le stesse rotte, che pur
    # finendo in 401 costa comunque una risoluzione di credenziale a testa.
    it "senza Bearer, in lettura o su un altro path del namespace si resta nel contatore di /api" do
      senza_bearer = attack_request("/api/v1/servers/samples", bearer: nil)
      lettura = attack_request("/api/v1/servers/samples", method: "GET")
      altro_path = attack_request("/api/v1/servers/qualcosa_altro")

      expect(api_throttle.block.call(senza_bearer)).to eq("203.0.113.7")
      expect(api_throttle.block.call(lettura)).to eq("203.0.113.7")
      expect(api_throttle.block.call(altro_path)).to eq("203.0.113.7")
    end

    it "quel che esce da /api è esattamente quel che entra nel tetto degli agent" do
      %w[/api/v1/servers/samples /api/v1/servers/action_claims /api/v1/servers/qualcosa_altro
         /api/v1/projects/abc/events].each do |path|
        [ "POST", "GET" ].each do |method|
          [ token, nil ].each do |bearer|
            request = attack_request(path, method: method, bearer: bearer)
            fuori_da_api = api_throttle.block.call(request).nil?
            dentro_agli_agent = throttle.block.call(request).present?

            expect(fuori_da_api).to eq(dentro_agli_agent), "#{method} #{path} bearer=#{!bearer.nil?}"
          end
        end
      end
    end

    it "il tetto degli agent regge una flotta intera, non una macchina sola" do
      expect(throttle.limit).to be >= 600
    end
  end

  # La rete di sicurezza: se il freno scatta lo stesso (per un'altra ragione), il backend deve almeno
  # SAPERLO, o tornerebbe a leggere il proprio rifiuto come una macchina caduta.
  describe "un rifiuto a un agent viene registrato" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    def throttled(path, bearer: token)
      request = attack_request(path, bearer: bearer)
      request.env["rack.attack.matched"] = "servers_ingest/agent"
      ActiveSupport::Notifications.instrument("throttle.rack_attack", request: request)
    end

    it "si ricorda la credenziale rifiutata, non un generico «è successo»" do
      throttled("/api/v1/servers/samples")

      expect(Servers::IngestRejections.recent_keys)
        .to contain_exactly(Digest::SHA256.hexdigest(token)[0, 32])
    end

    it "il rifiuto di una richiesta che non è di un agent non registra niente" do
      throttled("/api/v1/projects/abc/events")

      expect(Servers::IngestRejections.recent_keys).to be_empty
    end

    it "un rifiuto senza credenziale non registra niente" do
      throttled("/api/v1/servers/samples", bearer: nil)

      expect(Servers::IngestRejections.recent_keys).to be_empty
    end
  end
end
