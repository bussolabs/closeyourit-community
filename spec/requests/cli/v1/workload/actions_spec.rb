# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Workload::Actions", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:team) { create(:team, organization: organization) }
  let(:other_team) { create(:team, organization: organization) }

  before do
    create(:membership, account: account, organization: organization)
    create(:team_membership, team: team, account: account)
  end

  let(:secret) { Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "autenticazione" do
    it "senza bearer → 401" do
      get "/cli/v1/workload/actions"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET index" do
    it "ritorna solo le action dei team a cui appartiene l'account" do
      mine = create(:workload_action, team: team, organization: organization)
      create(:workload_action, team: other_team, organization: organization)

      get "/cli/v1/workload/actions", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |a| a["id"] }
      expect(ids).to contain_exactly(mine.id)
      expect(response.parsed_body["meta"]).to include("total" => 1)
    end
  end

  describe "GET show" do
    it "action di un altro team → 404 (anti-BOLA)" do
      action = create(:workload_action, team: other_team, organization: organization)

      get "/cli/v1/workload/actions/#{action.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "crea la action per il mio team → 201 envelope data" do
      post "/cli/v1/workload/actions", params: { team_id: team.id, title: "Fiera" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("title" => "Fiera", "team" => team.name)
    end

    it "team non mio → 422 R422-WORKLOAD-001" do
      post "/cli/v1/workload/actions", params: { team_id: other_team.id, title: "X" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-WORKLOAD-001")
    end
  end

  describe "PATCH update" do
    it "aggiorna la mia action" do
      action = create(:workload_action, team: team, organization: organization, title: "Vecchio")

      patch "/cli/v1/workload/actions/#{action.id}", params: { title: "Nuovo" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(action.reload.title).to eq("Nuovo")
    end
  end

  describe "DELETE destroy" do
    it "elimina la mia action → 204" do
      action = create(:workload_action, team: team, organization: organization)

      delete "/cli/v1/workload/actions/#{action.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Workload::Action.exists?(action.id)).to be(false)
    end
  end

  describe "participants" do
    let(:action) { create(:workload_action, team: team, organization: organization) }

    it "POST aggiunge un membro del team → 201" do
      teammate = create(:account).tap { |a| create(:team_membership, team: team, account: a) }

      post "/cli/v1/workload/actions/#{action.id}/participants", params: { account_id: teammate.id }, headers: headers

      expect(response).to have_http_status(:created)
      expect(action.reload.participants).to include(teammate)
    end

    it "POST con account estraneo al team → 422 R422-WORKLOAD-002" do
      outsider = create(:account)

      post "/cli/v1/workload/actions/#{action.id}/participants", params: { account_id: outsider.id }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-WORKLOAD-002")
    end

    it "DELETE rimuove un partecipante" do
      teammate = create(:account).tap { |a| create(:team_membership, team: team, account: a) }
      action.participations.create!(account: teammate)

      delete "/cli/v1/workload/actions/#{action.id}/participants/#{teammate.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(action.reload.participants).to be_empty
    end
  end

  describe "promotion" do
    let(:project) { create(:project, organization: organization) }
    let(:action) { create(:workload_action, team: team, organization: organization, title: "Firma") }

    before do
      create(:team_project_access, team: team, project: project)
      Types::InstallDefaults.call(organization: organization)
    end

    it "POST genera il ticket → 201 e linka la action" do
      expect do
        post "/cli/v1/workload/actions/#{action.id}/promotion", params: { project_id: project.id, description: "API" }, headers: headers
      end.to change(Ticketing::Ticket, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(action.reload.ticket).to eq(Ticketing::Ticket.last)
    end

    it "action già linkata → 422 R422-WORKLOAD-003" do
      linked = create(:workload_action, :with_ticket, team: team, organization: organization)

      post "/cli/v1/workload/actions/#{linked.id}/promotion", params: { project_id: project.id }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-WORKLOAD-003")
    end
  end
end
