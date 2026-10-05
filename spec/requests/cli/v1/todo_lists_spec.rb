# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::TodoLists", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "autenticazione" do
    it "senza bearer → 401 R401-CLIAUTH-001" do
      get "/cli/v1/todo_lists"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
    end
  end

  describe "GET /cli/v1/todo_lists" do
    it "ritorna solo le liste possedute nell'org" do
      mine = create(:todo_list, account:, organization:, name: "Mia")
      other = create(:account)
      create(:membership, account: other, organization:)
      create(:todo_list, account: other, organization:, name: "Altrui")

      get "/cli/v1/todo_lists", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |l| l["id"] }
      expect(ids).to contain_exactly(mine.id)
    end
  end

  describe "POST /cli/v1/todo_lists" do
    it "crea la lista → 201 envelope data" do
      post "/cli/v1/todo_lists", params: { name: "Oggi", color: "indigo" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["name"]).to eq("Oggi")
    end

    it "nome vuoto → 422 R422-TODOLIST-001" do
      post "/cli/v1/todo_lists", params: { name: "" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TODOLIST-001")
    end
  end

  describe "GET /cli/v1/todo_lists/:id" do
    it "mostra la mia lista → 200" do
      list = create(:todo_list, account:, organization:)
      get "/cli/v1/todo_lists/#{list.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(list.id)
    end

    it "lista di un altro account → 404 (anti-BOLA)" do
      other = create(:account)
      create(:membership, account: other, organization:)
      list = create(:todo_list, account: other, organization:)

      get "/cli/v1/todo_lists/#{list.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /cli/v1/todo_lists/:id" do
    it "aggiorna → 200" do
      list = create(:todo_list, account:, organization:, name: "Vecchio")
      patch "/cli/v1/todo_lists/#{list.id}", params: { name: "Nuovo" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(list.reload.name).to eq("Nuovo")
    end
  end

  describe "DELETE /cli/v1/todo_lists/:id" do
    it "elimina → 204" do
      list = create(:todo_list, account:, organization:)
      delete "/cli/v1/todo_lists/#{list.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Todos::List.exists?(list.id)).to be(false)
    end
  end
end
