# frozen_string_literal: true

require "rails_helper"

# CYRA-170 FIX-1: il login e il secondo fattore devono essere rate-limitati. rack-attack è disabilitato
# nei test (spec/support/rack_attack.rb) → i throttle si verificano invocando direttamente il loro block
# sul path/metodo, come rack_attack_ingest_spec.
RSpec.describe "Rack::Attack — auth", type: :request do
  def attack_request(path, method: "POST")
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => "203.0.113.7"))
  end

  { "login/ip" => "/login", "two_factor/ip" => "/login/2fa", "password_reset/ip" => "/passwords" }.each do |rule, path|
    [ "", "/", ".json", ".json/" ].each do |suffix|
      it "throttles #{path}#{suffix} under #{rule}" do
        throttle = Rack::Attack.throttles.fetch(rule)
        expect(throttle.block.call(attack_request("#{path}#{suffix}"))).to eq("203.0.113.7")
      end
    end
  end

  describe "throttle login/ip" do
    let(:throttle) { Rack::Attack.throttles.fetch("login/ip") }

    it "matcha il POST /login (path reale del login, non /session)" do
      expect(throttle.block.call(attack_request("/login"))).to eq("203.0.113.7")
    end

    it "NON matcha /session (path errato che lasciava il login non protetto)" do
      expect(throttle.block.call(attack_request("/session"))).to be_nil
    end

    it "NON matcha il GET /login (solo il POST)" do
      expect(throttle.block.call(attack_request("/login", method: "GET"))).to be_nil
    end
  end

  describe "throttle two_factor/ip" do
    let(:throttle) { Rack::Attack.throttles.fetch("two_factor/ip") }

    it "matcha il POST /login/2fa (challenge del secondo fattore)" do
      expect(throttle.block.call(attack_request("/login/2fa"))).to eq("203.0.113.7")
    end

    it "NON matcha il GET /login/2fa (solo il POST)" do
      expect(throttle.block.call(attack_request("/login/2fa", method: "GET"))).to be_nil
    end
  end

  # CYRA-249: chiusa /signup, l'accettazione di un invito è l'unica richiesta anonima che crea un
  # account. Il token è firmato e non si indovina, ma il freno c'è comunque — come su login e reset.
  describe "throttle invitation_accept/ip" do
    let(:throttle) { Rack::Attack.throttles.fetch("invitation_accept/ip") }

    it "matcha il PATCH /invitations/:token (accettazione)" do
      expect(throttle.block.call(attack_request("/invitations/abc123", method: "PATCH"))).to eq("203.0.113.7")
    end

    it "matcha il PUT /invitations/:token (stesso update, verbo alternativo dei form)" do
      expect(throttle.block.call(attack_request("/invitations/abc123", method: "PUT"))).to eq("203.0.113.7")
    end

    it "NON matcha il GET del modulo (solo l'invio)" do
      expect(throttle.block.call(attack_request("/invitations/abc123/edit", method: "GET"))).to be_nil
    end
  end

  # CYRA-719: entrare nei panni di un altro utente è la capacità god più pericolosa e non aveva alcun
  # freno. Il codice a sei cifre chiesto sull'avvio (re-auth) sarebbe indovinabile a raffica senza limite.
  describe "throttle impersonation/ip (CYRA-719)" do
    let(:throttle) { Rack::Attack.throttles.fetch("impersonation/ip") }

    it "matcha il POST /impersonation (avvio)" do
      expect(throttle.block.call(attack_request("/impersonation"))).to eq("203.0.113.7")
    end

    it "matcha anche con estensione di formato: .json non aggira il limite" do
      expect(throttle.block.call(attack_request("/impersonation.json"))).to eq("203.0.113.7")
    end

    it "NON matcha il DELETE /impersonation (l'uscita non va mai frenata)" do
      expect(throttle.block.call(attack_request("/impersonation", method: "DELETE"))).to be_nil
    end

    it "NON matcha il GET /impersonation/new (la pagina di conferma non spende tentativi)" do
      expect(throttle.block.call(attack_request("/impersonation/new", method: "GET"))).to be_nil
    end
  end

  describe "throttle two_factor_manage/ip (FIX-I)" do
    let(:throttle) { Rack::Attack.throttles.fetch("two_factor_manage/ip") }

    it "matcha il POST /account/2fa/enable (attivazione)" do
      expect(throttle.block.call(attack_request("/account/2fa/enable"))).to eq("203.0.113.7")
    end

    it "matcha il DELETE /account/2fa (disattivazione)" do
      expect(throttle.block.call(attack_request("/account/2fa", method: "DELETE"))).to eq("203.0.113.7")
    end

    it "NON matcha il GET /account/2fa (lettura, solo POST/DELETE)" do
      expect(throttle.block.call(attack_request("/account/2fa", method: "GET"))).to be_nil
    end
  end
end
