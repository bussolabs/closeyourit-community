# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::TodoLists::Items", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:list) { create(:todo_list, account:, organization:) }

  describe "GET /cli/v1/todo_lists/:id/items" do
    it "elenca le voci ordinate → 200" do
      create(:todo_item, list:, title: "A", position: 0)
      create(:todo_item, list:, title: "B", position: 1)
      get "/cli/v1/todo_lists/#{list.id}/items", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |i| i["title"] }).to eq(%w[A B])
    end
  end

  describe "POST /cli/v1/todo_lists/:id/items" do
    it "crea la voce → 201" do
      post "/cli/v1/todo_lists/#{list.id}/items", params: { title: "Fix login" }, headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["title"]).to eq("Fix login")
    end

    it "titolo vuoto → 422 R422-TODOITEM-001" do
      post "/cli/v1/todo_lists/#{list.id}/items", params: { title: "" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TODOITEM-001")
    end

    it "link a ticket della stessa org → 201 con ticket_code" do
      ticket = create(:ticket, organization:)
      post "/cli/v1/todo_lists/#{list.id}/items",
           params: { title: "Chiudi bug", ticket_id: ticket.id }, headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["ticket_id"]).to eq(ticket.id)
      expect(response.parsed_body["data"]["ticket_code"]).to eq(ticket.code)
    end

    it "ticket di un'altra org → 422 R422-TODOITEM-001 (anti-leak tenant)" do
      ticket = create(:ticket, organization: create(:organization))
      post "/cli/v1/todo_lists/#{list.id}/items",
           params: { title: "X", ticket_id: ticket.id }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TODOITEM-001")
    end

    it "lista di un altro account → 404 (anti-BOLA)" do
      other = create(:account)
      create(:membership, account: other, organization:)
      foreign = create(:todo_list, account: other, organization:)
      post "/cli/v1/todo_lists/#{foreign.id}/items", params: { title: "X" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /cli/v1/todo_lists/:id/items/:id" do
    it "aggiorna il titolo → 200" do
      item = create(:todo_item, list:, title: "Vecchio")
      patch "/cli/v1/todo_lists/#{list.id}/items/#{item.id}", params: { title: "Nuovo" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(item.reload.title).to eq("Nuovo")
    end
  end

  describe "DELETE /cli/v1/todo_lists/:id/items/:id" do
    it "elimina → 204" do
      item = create(:todo_item, list:)
      delete "/cli/v1/todo_lists/#{list.id}/items/#{item.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Todos::Item.exists?(item.id)).to be(false)
    end
  end

  describe "completion (spunta)" do
    it "PUT completa la voce → 200 done=true" do
      item = create(:todo_item, list:, done: false)
      put "/cli/v1/todo_lists/#{list.id}/items/#{item.id}/completion", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["done"]).to be(true)
      expect(item.reload.done?).to be(true)
    end

    it "DELETE riapre la voce → 200 done=false" do
      item = create(:todo_item, :done, list:)
      delete "/cli/v1/todo_lists/#{list.id}/items/#{item.id}/completion", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["done"]).to be(false)
      expect(item.reload.done?).to be(false)
    end
  end
end
