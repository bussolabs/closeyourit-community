# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::TodoLists::Sharings", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:list) { create(:todo_list, account:, organization:) }

  def member!
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end

  describe "PUT /cli/v1/todo_lists/:id/sharing" do
    it "imposta i destinatari → 200" do
      m = member!
      put "/cli/v1/todo_lists/#{list.id}/sharing", params: { account_ids: [ m.id ] }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |a| a["id"] }).to contain_exactly(m.id)
      expect(list.reload.shared_accounts).to contain_exactly(m)
    end

    it "destinatario non membro → 422 R422-TODOSHARE-001" do
      outsider = create(:account)
      put "/cli/v1/todo_lists/#{list.id}/sharing", params: { account_ids: [ outsider.id ] }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TODOSHARE-001")
    end
  end

  describe "GET /cli/v1/todo_lists/:id/sharing" do
    it "elenca i destinatari → 200" do
      m = member!
      create(:todo_share, list:, account: m)
      get "/cli/v1/todo_lists/#{list.id}/sharing", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |a| a["id"] }).to contain_exactly(m.id)
    end
  end

  describe "anti-BOLA" do
    it "sharing su lista altrui → 404" do
      other = create(:account)
      create(:membership, account: other, organization:)
      foreign = create(:todo_list, account: other, organization:)
      get "/cli/v1/todo_lists/#{foreign.id}/sharing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
