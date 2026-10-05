# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::Settings", type: :request do
  # CYRA-170: il god in Valhalla passa dal 2FA (attivato al volo + secondo fattore completato).
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  let(:god) { create(:account, god: true) }

  describe "GET /valhalla/settings" do
    it "god → 200 con il campo retention" do
      sign_in_as(god)
      get valhalla_settings_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("logs-retention-days")
    end

    it "god → 200 con i campi retention errori/performance/server/uptime (CYRA-159)" do
      sign_in_as(god)
      get valhalla_settings_path
      expect(response.body).to include("errors-retention-days")
      expect(response.body).to include("performance-retention-days")
      expect(response.body).to include("servers-retention-days")
      expect(response.body).to include("uptime-retention-days")
    end

    it "account non-god → redirect alla home" do
      sign_in_as(create(:account, god: false))
      get valhalla_settings_path
      expect(response).to redirect_to(root_path)
    end

    it "non autenticato → redirect al login" do
      get valhalla_settings_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "PATCH /valhalla/settings" do
    before { sign_in_as(god) }

    it "salva una retention valida" do
      patch valhalla_settings_path, params: { logs_retention_days: 30 }
      expect(response).to redirect_to(valhalla_settings_path)
      expect(Settings::Global.instance.logs_retention_days).to eq(30)
    end

    it "rifiuta un valore fuori da 1..365 → 422" do
      patch valhalla_settings_path, params: { logs_retention_days: 400 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "salva i default di sistema per errori/performance/server/uptime (CYRA-159)" do
      patch valhalla_settings_path, params: { errors_retention_days: 45, performance_retention_days: 45,
                                              servers_retention_days: 45, uptime_retention_days: 400 }
      expect(response).to redirect_to(valhalla_settings_path)
      settings = Settings::Global.instance
      expect(settings.errors_retention_days).to eq(45)
      expect(settings.performance_retention_days).to eq(45)
      expect(settings.servers_retention_days).to eq(45)
      expect(settings.uptime_retention_days).to eq(400)
    end

    it "rifiuta uptime fuori da 1..730 → 422" do
      patch valhalla_settings_path, params: { uptime_retention_days: 999 }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # Gli switch AI arrivano in JSON dallo Stimulus ui--switch: rack_test non esegue JS, quindi la
  # persistenza è coperta qui (stessa convenzione dei toggle della tab GitHub).
  describe "PATCH /valhalla/settings — interruttori AI" do
    before { sign_in_as(god) }

    it "spegne un servizio e risponde 200 senza redirect" do
      patch valhalla_settings_path,
            params: { ai_agent_gate_enabled: "0" }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(Settings::Global.instance.ai_agent_gate_enabled).to be(false)
      expect(Ai::Feature.enabled?(:agent_gate)).to be(false)
    end

    it "riaccende un servizio spento" do
      Settings::Global.instance.update!(ai_triage_enabled: false)

      patch valhalla_settings_path,
            params: { ai_triage_enabled: "1" }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(Settings::Global.instance.ai_triage_enabled).to be(true)
    end

    it "non tocca gli altri servizi" do
      patch valhalla_settings_path,
            params: { ai_embeddings_enabled: "0" }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      settings = Settings::Global.instance
      expect(settings.ai_embeddings_enabled).to be(false)
      expect(settings.ai_agent_gate_enabled).to be(true)
      expect(settings.ai_assistant_chat_enabled).to be(true)
    end

    it "un account non-god non può spegnere niente" do
      delete logout_path if respond_to?(:logout_path)
      sign_in_as(create(:account, god: false))

      patch valhalla_settings_path,
            params: { ai_agent_gate_enabled: "0" }.to_json,
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

      expect(Settings::Global.instance.ai_agent_gate_enabled).to be(true)
    end
  end

  describe "GET /valhalla/settings — pannello AI" do
    it "mostra uno switch per ogni servizio" do
      sign_in_as(god)
      get valhalla_settings_path

      Ai::Feature::KEYS.each do |key|
        expect(response.body).to include("ai-switch-#{key}")
      end
    end

    # CYRA-840: le chiavi dei testi sono costruite per interpolazione, e un servizio senza traduzione
    # compariva in pagina come «Label»/«Hint». Il testo atteso è scritto qui, non riletto dal file.
    it "chiama per nome i servizi di compattazione e rietichettatura, in italiano" do
      god.update!(locale: "it")
      sign_in_as(god)
      get valhalla_settings_path

      expect(response.body).to include("Riassunto dei commenti storici")
      expect(response.body).to include("Rietichettatura delle analisi tecniche")
      expect(response.body).not_to include("translation_missing")
    end

    it "chiama per nome i servizi di compattazione e rietichettatura, in inglese" do
      god.update!(locale: "en")
      sign_in_as(god)
      get valhalla_settings_path

      expect(response.body).to include("Historical comment summaries")
      expect(response.body).to include("Technical analysis relabelling")
      expect(response.body).not_to include("translation_missing")
    end
  end
end
