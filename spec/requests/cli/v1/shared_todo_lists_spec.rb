# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::SharedTodoLists", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Lista di un altro membro, condivisa CON me.
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:shared_list) do
    create(:todo_list, account: owner, organization:).tap do |list|
      create(:todo_share, list:, account:)
    end
  end

  describe "GET /cli/v1/shared_todo_lists" do
    it "elenca le liste condivise con me (non le mie)" do
      shared_list
      create(:todo_list, account:, organization:) # mia, non deve comparire

      get "/cli/v1/shared_todo_lists", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |l| l["id"] }
      expect(ids).to contain_exactly(shared_list.id)
    end

    it "espone l'owner della lista ricevuta" do
      shared_list
      get "/cli/v1/shared_todo_lists", headers: headers
      expect(response.parsed_body["data"].first["owner"]["id"]).to eq(owner.id)
    end
  end

  describe "GET /cli/v1/shared_todo_lists/:id" do
    it "mostra una lista condivisa con me → 200" do
      get "/cli/v1/shared_todo_lists/#{shared_list.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(shared_list.id)
    end

    it "lista non condivisa con me → 404 (anti-BOLA)" do
      foreign = create(:todo_list, account: owner, organization:) # non condivisa con me
      get "/cli/v1/shared_todo_lists/#{foreign.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
