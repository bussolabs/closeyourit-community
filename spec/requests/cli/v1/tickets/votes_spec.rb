# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Votes", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "vota (PUT) → 200, voted true e votes_count 1" do
      expect do
        put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers
      end.to change { ticket.reload.votes_count }.from(0).to(1)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["voted"]).to be(true)
      expect(data["votes_count"]).to eq(1)
      expect(data["ticket_id"]).to eq(ticket.id)
    end

    it "ri-votare è idempotente → resta 1 voto" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers
      expect do
        put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers
      end.not_to change { ticket.reload.votes_count }
      expect(response).to have_http_status(:ok)
      expect(ticket.reload.votes_count).to eq(1)
    end

    it "rimuove il voto (DELETE) → votes_count 0 e voted false" do
      ticket.votes.create!(account:)
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["voted"]).to be(false)
      expect(data["votes_count"]).to eq(0)
      expect(ticket.reload.votes_count).to eq(0)
    end

    it "DELETE senza voto è idempotente → 200, votes_count 0" do
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["votes_count"]).to eq(0)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      put "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/vote", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "collisione concorrente (RecordNotUnique) → trattata come successo (idempotente), 200" do
      allow_any_instance_of(ActiveRecord::Associations::CollectionProxy)
        .to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordNotUnique)

      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers

      expect(response).to have_http_status(:ok)
    end
  end

  context "member che vede il progetto (baseline: vota)" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "può votare → 200, votes_count 1" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers
      expect(response).to have_http_status(:ok)
      expect(ticket.reload.votes_count).to eq(1)
    end
  end

  context "member che NON vede il progetto (strict Fase E)" do
    before { create(:membership, account:, organization:, role: :member) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "non vede il progetto → 404 (anti-BOLA)" do
      put "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/vote", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
