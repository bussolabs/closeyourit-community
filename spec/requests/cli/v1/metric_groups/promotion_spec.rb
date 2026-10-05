# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::MetricGroups::Promotion", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  # I default status/priority del ticket servono perché PromoteToTicket → CreateTicket li risolve.
  before { Types::InstallDefaults.call(organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def promotion_path(project_id, group_id)
    "/cli/v1/projects/#{project_id}/metric_groups/#{group_id}/promotion"
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    group = create(:metric_group, project:)
    put promotion_path(project.id, group.id)
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (metrics.promote)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "promuove il gruppo → 201 col ticket creato, group.promoted?" do
      group = create(:metric_group, project:)

      expect do
        put promotion_path(project.id, group.id), headers: headers
      end.to change(Ticketing::Ticket, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("id", "code")
      expect(response.parsed_body["data"]["id"]).to eq(group.reload.ticket_id)
      expect(group).to be_promoted
    end

    it "gruppo già promosso → 422 R422-METRIC-001, nessun secondo ticket" do
      group = create(:metric_group, project:)
      put promotion_path(project.id, group.id), headers: headers
      expect(response).to have_http_status(:created)

      expect do
        put promotion_path(project.id, group.id), headers: headers
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-METRIC-001")
    end

    it "gruppo di un'altra org → 404 (anti-BOLA)" do
      other = create(:metric_group)
      put promotion_path(other.project_id, other.id), headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "gruppo di un altro progetto della stessa org → 404 (anti-BOLA find)" do
      other_group = create(:metric_group, project: create(:project, organization:))
      put promotion_path(project.id, other_group.id), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  context "member che vede il progetto ma senza metrics.promote" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "NON può promuovere → 403 R403-CLIAUTH-002, nessun ticket" do
      group = create(:metric_group, project:)

      expect do
        put promotion_path(project.id, group.id), headers: headers
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(group.reload).not_to be_promoted
    end
  end
end
