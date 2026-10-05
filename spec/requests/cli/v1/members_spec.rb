# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Members", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/members"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (members.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con account_id, email e membership_role" do
      client = create(:account, email: "client@example.com")
      create(:membership, account: client, organization:, role: :customer)

      get "/cli/v1/members", headers: headers

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["data"]
      expect(rows.map { |r| r["email"] }).to include("client@example.com", account.email)
      row = rows.find { |r| r["email"] == "client@example.com" }
      expect(row["account_id"]).to eq(client.id)
      expect(row["membership_role"]).to eq("customer")
      expect(response.parsed_body["meta"]).to include("total")
    end

    it "esclude i membri di un'altra org (anti-BOLA)" do
      other = create(:membership) # altra org

      get "/cli/v1/members", headers: headers

      ids = response.parsed_body["data"].map { |r| r["account_id"] }
      expect(ids).not_to include(other.account_id)
    end

    it "update → 200 e aggiorna l'anagrafica dell'account" do
      target = create(:membership, organization:, role: :member)

      patch "/cli/v1/members/#{target.id}", headers: headers,
                                            params: { name: "Nuovo Nome", handle: "nuovo_handle" }

      expect(response).to have_http_status(:ok)
      expect(target.account.reload.name).to eq("Nuovo Nome")
      expect(target.account.handle).to eq("nuovo_handle")
    end

    it "update con email invalida → 422 R422-ACCOUNT-001" do
      target = create(:membership, organization:, role: :member)

      patch "/cli/v1/members/#{target.id}", headers: headers, params: { email: "non-una-email" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ACCOUNT-001")
    end

    it "update di una membership di un'altra org → 404 (anti-BOLA)" do
      other = create(:membership, role: :member)

      patch "/cli/v1/members/#{other.id}", headers: headers, params: { name: "X" }
      expect(response).to have_http_status(:not_found)
    end

    it "destroy → 204 e rimuove il membro dall'org" do
      target = create(:membership, organization:, role: :member)

      delete "/cli/v1/members/#{target.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Connections::Membership.exists?(target.id)).to be(false)
    end

    it "destroy dell'ultimo owner → 422 R422-MEMBER-004 (guard)" do
      owner_membership = organization.memberships.owner.find_by(account_id: account.id)

      delete "/cli/v1/members/#{owner_membership.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-MEMBER-004")
      expect(Connections::Membership.exists?(owner_membership.id)).to be(true)
    end

    it "destroy di una membership di un'altra org → 404 (anti-BOLA)" do
      other = create(:membership, role: :member)

      delete "/cli/v1/members/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # members.edit consente la modifica anagrafica; forbid_protected_target! protegge owner/god.
  context "attore con members.edit (non privilegiato)" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "members.edit" ], actor: owner_account)
    end

    it "modifica un membro normale → 200" do
      target = create(:membership, organization:, role: :member)

      patch "/cli/v1/members/#{target.id}", headers: headers, params: { name: "Rinominato" }

      expect(response).to have_http_status(:ok)
      expect(target.account.reload.name).to eq("Rinominato")
    end

    it "NON può modificare l'owner (target protetto) → 403" do
      owner_membership = organization.memberships.owner.find_by(account_id: owner_account.id)

      patch "/cli/v1/members/#{owner_membership.id}", headers: headers, params: { name: "Hack" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  context "membro senza members.edit" do
    before { create(:membership, account:, organization:, role: :member) }

    it "update → 403 R403-CLIAUTH-002" do
      target = create(:membership, organization:, role: :member)

      patch "/cli/v1/members/#{target.id}", headers: headers, params: { name: "X" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "destroy → 403 R403-CLIAUTH-002 (serve members.manage)" do
      target = create(:membership, organization:, role: :member)

      delete "/cli/v1/members/#{target.id}", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(Connections::Membership.exists?(target.id)).to be(true)
    end
  end

  context "membro senza members.view né members.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "index → 403 R403-CLIAUTH-002" do
      get "/cli/v1/members", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  # Allineato al canale Member: la lettura basta members.view (non serve members.manage).
  context "membro con members.view" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "members.view" ], actor: owner_account)
    end

    it "index → 200 (lettura consentita da members.view)" do
      get "/cli/v1/members", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end
end
