# frozen_string_literal: true

require "rails_helper"

# CYRA-230: elenco e decisione (approva/rifiuta) delle richieste di modifica ai secret dal canale CLI.
# Speculare a Member::Vault::ChangeRequests (web): stesso servizio Pending per l'elenco, stessi service
# di decisione (Approve/Reject) col vincolo 4-eyes, stesso anti-BOLA (CR risolta nei progetti visibili).
RSpec.describe "Cli::V1::Vault::ChangeRequests", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def token_for(acc, org: organization)
    Accounts::ApiTokens::Issue.call(account: acc, organization: org, name: "CLI").value[:secret]
  end

  def headers_for(acc, org: organization)
    { "Authorization" => "Bearer #{token_for(acc, org:)}" }
  end

  # secrets.manage è scoped: serve un override org-level PIÙ un link diretto al progetto (visibilità).
  # ORDINE OBBLIGATORIO come nello spec web: la project_membership genera la Connections::Membership
  # mancante, che SetAccountPermissions richiede già esistente.
  def grant_manage(account, on: project)
    create(:project_membership, account:, project: on)
    Authorization::SetAccountPermissions.call(organization: on.organization, account:, allow_keys: [ "secrets.manage" ], actor: owner)
  end

  def pending_change_request(requester:, target_project: project, target_environment: environment, **attrs)
    create(:secret_change_request, project: target_project, organization: target_project.organization,
           environment: target_environment, requested_by: requester, **attrs)
  end

  describe "environment authorization" do
    let!(:restricted_request) { pending_change_request(requester: create(:account)) }

    before do
      create(:account_secret_access, account: owner, project:, organization:, environment_codes: [ "staging" ])
    end

    it "does not list another account's production request" do
      get "/cli/v1/vault/change_requests", headers: headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).to be_empty
    end

    %w[approve reject].each do |decision|
      it "refuses a production #{decision} without changing the request" do
        post "/cli/v1/vault/change_requests/#{restricted_request.id}/#{decision}",
             params: { confirm: "1", reason: "Not approved" }, headers: headers_for(owner)

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body.dig("error", "code")).to eq("R403-CHANGEREQUEST-004")
        expect(restricted_request.reload).to be_pending
        expect(project.secret_variables).to be_empty
      end
    end
  end

  describe "GET index" do
    it "owner → 200, elenca le richieste pending coi metadati (mai il valore proposto)" do
      requester = create(:account)
      grant_manage(requester)
      pending_change_request(requester:, name: "API_KEY", value: "s3cr3t-in-chiaro")

      get "/cli/v1/vault/change_requests", headers: headers_for(owner)

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].find { |r| r["name"] == "API_KEY" }
      expect(row).to be_present
      expect(row["action"]).to eq("set")
      expect(row["status"]).to eq("pending")
      expect(row["project"]["key"]).to eq(project.key)
      expect(row["environment"]["code"]).to eq("production")
      expect(row["requested_by"]["email"]).to eq(requester.email)
      expect(row).not_to have_key("value")
      expect(response.body).not_to include("s3cr3t-in-chiaro")
    end

    it "una richiesta creata dal canale CLI compare nello stesso elenco" do
      project.update!(secret_approval_enabled: true)
      project.project_environments.find_by!(environment:).update!(approval_required: true)
      manager = create(:account)
      grant_manage(manager)

      post "/cli/v1/projects/#{project.id}/secrets", headers: headers_for(manager),
                                                     params: { confirm: "1", environment: "production", name: "CLI_MADE", value: "v" }
      expect(response).to have_http_status(:accepted)

      get "/cli/v1/vault/change_requests", headers: headers_for(manager)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |r| r["name"] }).to include("CLI_MADE")
    end

    it "non elenca le richieste di un progetto di un'altra org (scope org del token)" do
      other_project = create(:project)
      other_environment = create(:environment, organization: other_project.organization).tap { |e| other_project.environments << e }
      pending_change_request(requester: create(:account), target_project: other_project,
                             target_environment: other_environment, name: "FOREIGN")

      get "/cli/v1/vault/change_requests", headers: headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("FOREIGN")
    end
  end

  describe "POST approve" do
    it "manage (non richiedente) approva: applica, il secret cambia, la CR diventa applied" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY", value: "nuovo-valore")

      post "/cli/v1/vault/change_requests/#{change_request.id}/approve", params: { confirm: "1" }, headers: headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("applied")
      expect(change_request.reload.status).to eq("applied")
      expect(project.secret_variables.find_by(environment:, name: "API_KEY").value).to eq("nuovo-valore")
    end

    it "il richiedente non può approvare la propria richiesta → 403 R403-CHANGEREQUEST-001, resta pending" do
      requester = owner # owner ha secrets.manage ovunque, ma è il richiedente
      change_request = pending_change_request(requester:, name: "API_KEY")

      post "/cli/v1/vault/change_requests/#{change_request.id}/approve", params: { confirm: "1" }, headers: headers_for(owner)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CHANGEREQUEST-001")
      expect(change_request.reload.status).to eq("pending")
    end

    it "una richiesta già decisa → 409 R409-CHANGEREQUEST-001" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")
      change_request.update!(status: :applied, decided_by: owner, decided_at: Time.current)

      post "/cli/v1/vault/change_requests/#{change_request.id}/approve", params: { confirm: "1" }, headers: headers_for(owner)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]["code"]).to eq("R409-CHANGEREQUEST-001")
    end

    it "senza secrets.manage sul progetto (ma lo vede) → 403, la CR resta pending" do
      outsider = create(:account)
      create(:membership, account: outsider, organization:, role: :member)
      create(:project_membership, account: outsider, project:)
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")

      post "/cli/v1/vault/change_requests/#{change_request.id}/approve", headers: headers_for(outsider)

      expect(response).to have_http_status(:forbidden)
      expect(change_request.reload.status).to eq("pending")
    end

    it "CR di un progetto non visibile (altra org) → 404 anti-BOLA" do
      other_project = create(:project)
      other_environment = create(:environment, organization: other_project.organization).tap { |e| other_project.environments << e }
      foreign = pending_change_request(requester: create(:account), target_project: other_project,
                                       target_environment: other_environment, name: "FOREIGN")

      post "/cli/v1/vault/change_requests/#{foreign.id}/approve", headers: headers_for(owner)

      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-640: il canale CLI è l'unico da cui un account di servizio può presentarsi (non fa login web),
  # e il suo token si autentica come quello di una persona. Senza il guard nel service, una macchina con
  # secrets.manage chiudeva da sola il secondo passaggio della doppia approvazione.
  describe "POST approve/reject da un account di servizio" do
    let(:machine) { create(:account, :service) }

    before { grant_manage(machine) }

    it "approve da una macchina → 403 R403-CHANGEREQUEST-003, la CR resta pending, il secret NON cambia" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY", value: "nuovo-valore")

      post "/cli/v1/vault/change_requests/#{change_request.id}/approve", params: { confirm: "1" }, headers: headers_for(machine)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CHANGEREQUEST-003")
      expect(change_request.reload).to have_attributes(status: "pending", decided_by: nil, decided_at: nil)
      expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
    end

    it "reject da una macchina → 403 R403-CHANGEREQUEST-003, la CR resta pending" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")

      post "/cli/v1/vault/change_requests/#{change_request.id}/reject",
           params: { confirm: "1", reason: "non mi piace" }, headers: headers_for(machine)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CHANGEREQUEST-003")
      expect(change_request.reload).to have_attributes(status: "pending", reason: nil)
    end

    it "la macchina continua a VEDERE le richieste pending: il blocco è sulla decisione, non sulla lettura" do
      requester = create(:account)
      grant_manage(requester)
      pending_change_request(requester:, name: "API_KEY")

      get "/cli/v1/vault/change_requests", headers: headers_for(machine)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |r| r["name"] }).to include("API_KEY")
    end

    it "una PERSONA con gli stessi permessi decide dal terminale come prima" do
      change_request = pending_change_request(requester: machine, name: "API_KEY", value: "nuovo-valore")

      post "/cli/v1/vault/change_requests/#{change_request.id}/approve", params: { confirm: "1" }, headers: headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(change_request.reload.status).to eq("applied")
      expect(project.secret_variables.find_by(environment:, name: "API_KEY").value).to eq("nuovo-valore")
    end
  end

  describe "POST reject" do
    it "manage rifiuta con motivo: la CR diventa rejected, il secret non cambia" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY", value: "v")

      post "/cli/v1/vault/change_requests/#{change_request.id}/reject",
           params: { confirm: "1", reason: "Valore non sicuro" }, headers: headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(change_request.reload).to have_attributes(status: "rejected", reason: "Valore non sicuro")
      expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
    end

    it "motivo assente → 422 R422-CHANGEREQUEST-001, la CR resta pending" do
      requester = create(:account)
      grant_manage(requester)
      change_request = pending_change_request(requester:, name: "API_KEY")

      post "/cli/v1/vault/change_requests/#{change_request.id}/reject",
           params: { confirm: "1", reason: "" }, headers: headers_for(owner)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-CHANGEREQUEST-001")
      expect(change_request.reload.status).to eq("pending")
    end
  end
end
