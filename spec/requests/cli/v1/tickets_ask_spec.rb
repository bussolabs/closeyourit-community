# frozen_string_literal: true

require "rails_helper"

# "Chiedi ai ticket" dal terminale: gemello CLI di POST /member/tickets/ask. Asincrono come il web —
# accoda Ai::RunJob e risponde 202 con request_id — e l'esito si legge da GET /cli/v1/ai/requests/:id,
# che finora esisteva solo dentro il sito. L'esecuzione del service è coperta da
# spec/jobs/ai/run_job_spec.rb: qui si verificano perimetro congelato, envelope e confini.
RSpec.describe "Cli::V1::Tickets — chiedi ai ticket", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account:, organization:, role: :member)
    create(:project_membership, account:, project:)
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "POST /cli/v1/tickets/ask" do
    it "senza token → 401" do
      post "/cli/v1/tickets/ask", params: { question: "problemi col login?" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "202 con request_id, crea la richiesta pending (kind ticket_ask) e accoda il lavoro" do
      expect {
        post "/cli/v1/tickets/ask", params: { question: "problemi col login?" }, headers: headers
      }.to change(Ai::Request, :count).by(1).and have_enqueued_job(Ai::RunJob)

      expect(response).to have_http_status(:accepted)
      data = response.parsed_body["data"]
      expect(data["status"]).to eq("pending")

      request_record = Ai::Request.find(data["request_id"])
      expect(request_record.kind).to eq("ticket_ask")
      expect(request_record.account).to eq(account)
      expect(request_record.args["question"]).to eq("problemi col login?")
    end

    # Il perimetro si congela all'invio, come sul web: il job si fida di ciò che era visibile allora.
    it "accoda SOLO i progetti visibili al token, mai quelli altrui" do
      nascosto = create(:project, organization:) # nessuna project_membership

      post "/cli/v1/tickets/ask", params: { question: "segreto?" }, headers: headers

      request_record = Ai::Request.find(response.parsed_body.dig("data", "request_id"))
      expect(request_record.args["project_ids"]).to contain_exactly(project.id)
      expect(request_record.args["project_ids"]).not_to include(nascosto.id)
    end

    it "domanda vuota → 422 senza accodare nulla" do
      expect {
        post "/cli/v1/tickets/ask", params: { question: "   " }, headers: headers
      }.not_to change(Ai::Request, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-TICKET-005")
    end
  end

  describe "GET /cli/v1/ai/requests/:id" do
    it "senza token → 401" do
      get "/cli/v1/ai/requests/#{SecureRandom.uuid}"

      expect(response).to have_http_status(:unauthorized)
    end

    it "in lavorazione → pending" do
      request_record = create(:ai_request, account:, organization:)

      get "/cli/v1/ai/requests/#{request_record.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "status" => "pending" })
    end

    it "conclusa → done con il risultato" do
      request_record = create(:ai_request, account:, organization:)
      request_record.finish_ok!({ "answer" => "tre ticket aperti" })

      get "/cli/v1/ai/requests/#{request_record.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["status"]).to eq("done")
      expect(data["result"]).to eq({ "answer" => "tre ticket aperti" })
    end

    it "fallita → failed con codice e messaggio" do
      request_record = create(:ai_request, account:, organization:)
      request_record.finish_err!(code: "R502-AI-001", message: "gateway giù")

      get "/cli/v1/ai/requests/#{request_record.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["status"]).to eq("failed")
      expect(data["error"]).to eq({ "code" => "R502-AI-001", "message" => "gateway giù" })
    end

    it "id inesistente → 404" do
      get "/cli/v1/ai/requests/#{SecureRandom.uuid}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-AI-001")
    end

    # Dire "esiste ma non è tua" è già dire qualcosa: la richiesta di un altro non si distingue da
    # una che non c'è.
    it "richiesta di un altro account → 404" do
      altro = create(:account)
      create(:membership, account: altro, organization:, role: :member)
      estranea = create(:ai_request, account: altro, organization:)

      get "/cli/v1/ai/requests/#{estranea.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
