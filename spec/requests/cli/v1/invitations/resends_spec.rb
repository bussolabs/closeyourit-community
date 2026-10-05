# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Invitations::Resends", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  let!(:invitation) { create(:invitation, organization:) }

  it "senza bearer → 401" do
    put "/cli/v1/invitations/#{invitation.id}/resend"
    expect(response).to have_http_status(:unauthorized)
  end

  it "owner reinvia → 200 con accept_url e mail riaccodata" do
    expect do
      put "/cli/v1/invitations/#{invitation.id}/resend", headers: headers
    end.to have_enqueued_mail(Connections::InvitationsMailer, :invite)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["accept_url"]).to be_present
    expect(response.parsed_body["data"]["email"]).to eq(invitation.email)
  end

  it "invito di un'altra org → 404 (anti-BOLA)" do
    other = create(:invitation)

    put "/cli/v1/invitations/#{other.id}/resend", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "membro senza members.invite → 403" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

    put "/cli/v1/invitations/#{invitation.id}/resend",
        headers: { "Authorization" => "Bearer #{member_secret}" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
  end
  it "dichiara se le mail vengono consegnate" do
    put "/cli/v1/invitations/#{invitation.id}/resend", headers: headers
    expect(response.parsed_body["data"]["email_delivery"]).to be(true)
  end
end
