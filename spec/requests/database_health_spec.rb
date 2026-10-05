# frozen_string_literal: true

require "rails_helper"

# CYRA-754 · Il rilascio decideva che il server era pronto guardando /up, che risponde 200 anche col
# database irraggiungibile: il traffico passava sul contenitore nuovo e il sito serviva errori. Questo
# è l'endpoint che kamal-proxy interroga al rollout, e che tocca il primary davvero.
RSpec.describe "GET /up/database", type: :request do
  context "quando il database primary risponde" do
    it "risponde 200 così il rilascio procede come prima" do
      get "/up/database"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("database" => "up")
    end
  end

  context "quando il database primary non risponde" do
    before do
      allow(Ops::DatabaseHealth).to receive(:call)
        .and_return(Ops::DatabaseHealth::Result.new(available: false, error: "PG::ConnectionBad"))
    end

    it "risponde 503, così il rilascio non viene dichiarato pronto" do
      get "/up/database"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("database" => "down")
    end

    it "dice che tipo di guasto è, senza esporre host, porta o credenziali" do
      get "/up/database"

      expect(response.parsed_body).to include("error" => "PG::ConnectionBad")
    end
  end

  it "è pubblico: non chiede di autenticarsi, come /up e le sue gemelle" do
    get "/up/database"

    expect(response).not_to have_http_status(:found)
    expect(response).not_to have_http_status(:unauthorized)
  end

  # /up resta liveness PURA per contratto (knowledge-base/global/health-version.md): il controllo del
  # database vive accanto, non dentro. Se un giorno /up cominciasse a rispondere 503 a database giù,
  # il Docker HEALTHCHECK e Sablier ne uscirebbero cambiati senza che nessuno l'abbia deciso.
  it "non cambia /up, che resta 200 anche col database giù" do
    allow(Ops::DatabaseHealth).to receive(:call)
      .and_return(Ops::DatabaseHealth::Result.new(available: false, error: "PG::ConnectionBad"))

    get "/up"

    expect(response).to have_http_status(:ok)
  end
end
