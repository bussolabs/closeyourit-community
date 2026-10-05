# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::WorkspaceManifest do
  subject(:result) { described_class.call(host:) }

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
  # Host-first (CYAU-100): la fonte dei repository è la ProjectScope del service account dell'host, la
  # stessa autorità usata da Eligibility/claim/limits/delivery. Nessun Agent/Command/target.
  let(:service_account) do
    create(:account, :service).tap { |account| create(:project_membership, account:, project:) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }

  it "restituisce l'involucro completo con versione, digest e hint della workspace" do
    expect(result).to be_ok
    manifest = result.value
    expect(manifest[:version]).to eq(1)
    expect(manifest[:workspace_root_hint]).to eq("Lavoro/Github/Personale")
    expect(manifest[:digest]).to eq(Digest::SHA256.hexdigest(manifest[:repositories].to_json))
  end

  it "mappa il progetto visibile all'host con la struttura repo attesa" do
    entry = result.value[:repositories].sole

    expect(entry).to include(
      project_key: "CYRA",
      repo: "bussolabs/closeyourit-rails",
      default_branch: "main",
      path: "closeyourit-rails",
      group: nil
    )
  end

  it "preferisce il workspace_path esplicito al path derivato dal repo" do
    project.update!(workspace_path: "apps/closeyourit/closeyourit-rails")

    expect(result.value[:repositories].sole[:path]).to eq("apps/closeyourit/closeyourit-rails")
  end

  it "esclude i progetti privi di github_repository" do
    other = create(:project, organization:, key: "NORE")
    create(:project_membership, account: service_account, project: other)

    expect(result.value[:repositories].map { |repo| repo[:project_key] }).to contain_exactly("CYRA")
  end

  it "esclude i progetti che il service account dell'host non vede (fail-closed)" do
    Connections::ProjectMembership.where(account: service_account, project:).delete_all

    expect(result.value[:repositories]).to be_empty
  end

  it "è vuoto quando l'host non ha un service account (mai fail-open)" do
    host.update_column(:service_account_id, nil)

    expect(result.value[:repositories]).to be_empty
  end

  it "non vede i progetti di un'altra organizzazione" do
    other_project = create(:project, organization: create(:organization), key: "ALTR")
    create(:github_repository, project: other_project, full_name: "bussolabs/altro")

    expect(result.value[:repositories].map { |repo| repo[:project_key] }).to contain_exactly("CYRA")
  end

  it "deriva il path sotto la cartella del gruppo quando il progetto appartiene a un gruppo" do
    group = create(:group, organization:, name: "CloseYourIt")
    project.update!(group:)

    entry = result.value[:repositories].sole
    expect(entry[:path]).to eq("closeyourit/closeyourit-rails")
    expect(entry[:group]).to eq("CloseYourIt")
  end

  it "ordina le voci per path e non duplica lo stesso progetto" do
    beta = create(:project, organization:, key: "BETA")
    create(:github_repository, project: beta, full_name: "bussolabs/aaa-first",
                               installation: repository.installation)
    create(:project_membership, account: service_account, project: beta)

    paths = result.value[:repositories].map { |repo| repo[:path] }
    expect(paths).to eq(%w[aaa-first closeyourit-rails])
  end
end
