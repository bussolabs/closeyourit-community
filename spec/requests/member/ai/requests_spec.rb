# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ai::Requests", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }

  before { create(:membership, account: member, organization: org, role: :member) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "non autenticato → redirect login" do
    get member_ai_request_path(SecureRandom.uuid)
    expect(response).to redirect_to(login_path)
  end

  context "autenticato" do
    before { sign_in(member) }

    it "richiesta pending → status pending" do
      request_record = create(:ai_request, account: member, organization: org)

      get member_ai_request_path(request_record)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "status" => "pending" })
    end

    it "richiesta done → status done con result" do
      request_record = create(:ai_request, account: member, organization: org)
      request_record.finish_ok!({ "summary" => "tutto ok" })

      get member_ai_request_path(request_record)

      data = response.parsed_body["data"]
      expect(data["status"]).to eq("done")
      expect(data["result"]).to eq({ "summary" => "tutto ok" })
    end

    it "richiesta failed → status failed con errore" do
      request_record = create(:ai_request, account: member, organization: org)
      request_record.finish_err!(code: "R502-AI-001", message: "gateway giù")

      get member_ai_request_path(request_record)

      data = response.parsed_body["data"]
      expect(data["status"]).to eq("failed")
      expect(data["error"]).to eq({ "code" => "R502-AI-001", "message" => "gateway giù" })
    end

    it "id inesistente → 404 R404-AI-001" do
      get member_ai_request_path(SecureRandom.uuid)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-AI-001")
    end

    it "richiesta di un ALTRO account → 404 (anti-BOLA)" do
      other_account = create(:account)
      create(:membership, account: other_account, organization: org, role: :member)
      foreign = create(:ai_request, account: other_account, organization: org)

      get member_ai_request_path(foreign)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-AI-001")
    end
  end
end
