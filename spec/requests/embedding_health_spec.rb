# frozen_string_literal: true

require "rails_helper"

# CYEM-2 · Lo smoke post-deploy interroga questo endpoint: se il servizio di embedding non risponde
# il rilascio deve fallire, invece di partire verde lasciando ricerca semantica, collegamenti e
# deduplica ferme senza che nessuno lo sappia.
RSpec.describe "GET /up/embedding", type: :request do
  context "quando il servizio risponde" do
    before do
      allow(Embeddings::EmbedText).to receive(:call).and_return(
        Result.ok(Array.new(Ai::Constants::EMBEDDING_DIMENSIONS, 0.1))
      )
    end

    it "risponde 200 e dice quante dimensioni ha il vettore" do
      get "/up/embedding"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "embedding" => "up", "dimensions" => Ai::Constants::EMBEDDING_DIMENSIONS
      )
    end
  end

  context "quando il servizio non risponde" do
    before do
      allow(Embeddings::EmbedText).to receive(:call).and_return(
        Result.err(AppError.new("connessione rifiutata", code: "R502-AI-001", status: :bad_gateway))
      )
    end

    it "risponde 503 col codice dell'errore, così lo smoke fallisce" do
      get "/up/embedding"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("embedding" => "down", "code" => "R502-AI-001")
    end
  end

  context "quando gli embedding sono spenti di proposito" do
    before { allow(Ai::Feature).to receive(:disabled?).with(:embeddings).and_return(true) }

    # Spento ≠ rotto: un'installazione senza embedding deve poter rilasciare.
    it "risponde 200 dicendo che è disattivato" do
      get "/up/embedding"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("embedding" => "disabled")
    end
  end

  it "è pubblico: non chiede di autenticarsi" do
    allow(Embeddings::EmbedText).to receive(:call).and_return(
      Result.ok(Array.new(Ai::Constants::EMBEDDING_DIMENSIONS, 0.1))
    )

    get "/up/embedding"

    expect(response).not_to have_http_status(:found)
    expect(response).not_to have_http_status(:unauthorized)
  end
end
