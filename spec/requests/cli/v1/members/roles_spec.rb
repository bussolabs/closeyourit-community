# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Members::Roles", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membership bersaglio: un altro account, ruolo member, nella stessa org.
  let!(:target) { create(:membership, organization:, role: :member) }

  it "senza bearer → 401" do
    put "/cli/v1/members/#{target.id}/role", params: { role: "admin" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "owner cambia ruolo → 200 e membership aggiornata" do
    put "/cli/v1/members/#{target.id}/role", headers: headers, params: { confirm: "1", role: "admin" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["membership_role"]).to eq("admin")
    expect(target.reload.role).to eq("admin")
  end

  it "ruolo non valido → 422 R422-MEMBER-001" do
    put "/cli/v1/members/#{target.id}/role", headers: headers, params: { confirm: "1", role: "owner" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to match(/\AR422-MEMBER-/)
    expect(target.reload.role).to eq("member")
  end

  it "membership di un'altra org → 404 (anti-BOLA, set_membership prima del gate)" do
    other = create(:membership, role: :member)

    put "/cli/v1/members/#{other.id}/role", headers: headers, params: { role: "admin" }
    expect(response).to have_http_status(:not_found)
  end

  it "membro senza members.manage → 403 e membership invariata" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

    put "/cli/v1/members/#{target.id}/role",
        headers: { "Authorization" => "Bearer #{member_secret}" }, params: { role: "admin" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    expect(target.reload.role).to eq("member")
  end
end
