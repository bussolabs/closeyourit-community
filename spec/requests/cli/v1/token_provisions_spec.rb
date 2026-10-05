# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tokens::Provisions", type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:source_project) { create(:project, organization:) }
  let(:destination_project) { create(:project, organization:) }
  let(:source_environment) do
    create(:environment, organization:, code: "staging").tap { |environment| source_project.environments << environment }
  end
  let(:destination_environment) do
    create(:environment, organization:, code: "development").tap do |environment|
      destination_project.environments << environment
    end
  end
  let(:headers) do
    secret = Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{secret}" }
  end
  let(:params) do
    {
      name: "CloseYourIt ingest",
      environment_id: source_environment.id,
      scopes: [ "ingest" ],
      idempotency_key: "request-123",
      sync_github: false,
      destination: {
        project_id: destination_project.id,
        environment_id: destination_environment.id,
        secret_name: "CLOSEYOURIT_TOKEN"
      }
    }
  end

  before { create(:membership, account:, organization:, role: :owner) }

  [ :source_project, :destination_project ].each do |target|
    it "enforces the #{target} override before creating a credential" do
      create(:account_secret_access, account:, project: public_send(target), organization:,
                                    environment_codes: [ "production" ])

      expect do
        post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers:, params:
      end.not_to change(Projects::Token, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-PROVISION-001")
      expect(destination_project.secret_variables).to be_empty
    end
  end

  it "does not retry a full export after destination access is restricted" do
    provision = create(:secret_provision, organization:, source_project:, source_environment:,
                                         destination_project:, destination_environment:, status: :failed)
    create(:account_secret_access, account:, project: destination_project, organization:,
                                  environment_codes: [ destination_environment.code ])

    expect do
      post "/cli/v1/projects/#{source_project.id}/tokens/provisions/#{provision.id}/retry",
           params: { confirm: "1" }, headers:
    end.not_to have_enqueued_job(Secrets::Provisions::SyncJob)

    expect(response).to have_http_status(:forbidden)
    expect(provision.reload).to be_failed
  end

  it "hides provision metadata after the destination environment is revoked" do
    provision = create(:secret_provision, organization:, source_project:, source_environment:,
                                         destination_project:, destination_environment:)
    create(:account_secret_access, account:, project: destination_project, organization:,
                                  environment_codes: [ "production" ])

    get "/cli/v1/projects/#{source_project.id}/tokens/provisions/#{provision.id}", headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-PROVISION-001")
  end

  it "crea una provision senza esporre secret, value o digest" do
    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers, params: params

    expect(response).to have_http_status(:created)
    data = response.parsed_body.fetch("data")
    expect(data.dig("token", "token_prefix")).to start_with("cyi_")
    expect(data.dig("provision", "status")).to eq("ready")
    expect(response.body).not_to match(/"(?:secret|value|token_digest)"/)
    expect(data.dig("token", "scopes")).to eq([ "ingest" ])
  end

  it "restituisce la stessa provision per una richiesta idempotente" do
    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers, params: params
    first_id = response.parsed_body.dig("data", "provision", "id")

    expect do
      post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers, params: params
    end.not_to change(Projects::Token, :count)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "provision", "id")).to eq(first_id)
  end

  it "richiede conferma esplicita quando uno dei due environment è production" do
    destination_environment.update!(code: "production")

    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers, params: params

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-PROVISION-003")
    expect(Projects::Token.count).to eq(0)
  end

  it "accetta production quando la conferma è esplicita" do
    destination_environment.update!(code: "production")

    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers,
                                                                      params: params.merge(confirm_production: true)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "provision", "status")).to eq("ready")
  end

  it "rispetta la restrizione environment dei service account su sorgente e destinazione" do
    organization.memberships.find_by!(account:).update!(secret_environment_codes: [ "staging" ])

    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers, params: params

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-PROVISION-001")
  end

  it "non permette di usare come destinazione un progetto invisibile" do
    other_account = create(:account)
    create(:membership, account: other_account, organization:, role: :member)
    create(:project_membership, account: other_account, project: source_project)
    role = create(:role, organization:)
    create(:role_permission, role:, permission_key: "tokens.manage")
    create(:role_permission, role:, permission_key: "secrets.provision")
    create(:account_role, account: other_account, organization:, role:)
    other_secret = Accounts::ApiTokens::Issue.call(account: other_account, organization:, name: "CLI").value[:secret]

    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1",
         headers: { "Authorization" => "Bearer #{other_secret}" }, params: params

    expect(response).to have_http_status(:not_found)
  end

  it "richiede secrets.provision anche quando il destinatario è visibile" do
    other_account = create(:account)
    create(:membership, account: other_account, organization:, role: :member)
    create(:project_membership, account: other_account, project: source_project)
    create(:project_membership, account: other_account, project: destination_project)
    role = create(:role, organization:)
    create(:role_permission, role:, permission_key: "tokens.manage")
    create(:account_role, account: other_account, organization:, role:)
    other_secret = Accounts::ApiTokens::Issue.call(account: other_account, organization:, name: "CLI").value[:secret]

    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1",
         headers: { "Authorization" => "Bearer #{other_secret}" }, params: params

    expect(response).to have_http_status(:forbidden)
  end

  it "rende 409 se la stessa idempotency key descrive una richiesta diversa" do
    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers, params: params

    expect do
      post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers,
                                                                        params: params.merge(name: "Diverso")
    end.not_to change(Projects::Token, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-PROVISION-001")
  end

  it "non sincronizza con retry una provision creata come solo-vault" do
    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers, params: params
    provision_id = response.parsed_body.dig("data", "provision", "id")
    provision = Secrets::Provision.find(provision_id)
    provision.update!(status: :failed)

    expect do
      post "/cli/v1/projects/#{source_project.id}/tokens/provisions/#{provision_id}/retry", params: { confirm: "1" }, headers: headers
    end.not_to have_enqueued_job(Secrets::Provisions::SyncJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-PROVISION-004")
  end

  it "show e retry restituiscono solo metadati e accodano l'id" do
    create(:github_repository, project: destination_project, sync_secrets: true,
                               staging_environment: destination_environment)
    post "/cli/v1/projects/#{source_project.id}/tokens/provisions?confirm=1", headers: headers,
                                                                      params: params.merge(sync_github: true)
    provision_id = response.parsed_body.dig("data", "provision", "id")
    provision = Secrets::Provision.find(provision_id)
    provision.update!(status: :failed, error_code: "R422-GITHUB-006",
                      error_message: "Sincronizzazione GitHub non riuscita")
    clear_enqueued_jobs

    get "/cli/v1/projects/#{source_project.id}/tokens/provisions/#{provision_id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to match(/"(?:secret|value|token_digest)"/)

    expect do
      post "/cli/v1/projects/#{source_project.id}/tokens/provisions/#{provision_id}/retry", params: { confirm: "1" }, headers: headers
    end.to have_enqueued_job(Secrets::Provisions::SyncJob).with(provision_id:)

    expect(response).to have_http_status(:accepted)
    expect(provision.reload).to be_pending_sync
  end
end
