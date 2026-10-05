# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Repository, type: :model do
  it "la factory produce un record valido" do
    expect(build(:github_repository)).to be_valid
  end

  describe "push sync dei secret (Fase 2)" do
    it "sync_secrets è opt-in (default false) e synced_secret_names parte vuoto" do
      repository = create(:github_repository)
      expect(repository.sync_secrets).to be(false)
      expect(repository.synced_secret_names).to eq({})
    end
  end

  describe "vincolo 1:1" do
    it "un progetto ha al più un repo" do
      repository = create(:github_repository)
      duplicate = build(:github_repository, project: repository.project, installation: repository.installation)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:project_id]).to be_present
    end

    it "un repo (installation + repo_id) è agganciato ad al più un progetto" do
      repository = create(:github_repository)
      duplicate = build(:github_repository, installation: repository.installation, repo_id: repository.repo_id)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:repo_id]).to be_present
    end
  end

  describe "integrità tenant" do
    it "richiede installazione della stessa org del progetto" do
      project = create(:project)
      foreign_installation = create(:github_installation)

      repository = build(:github_repository, project: project, installation: foreign_installation)

      expect(repository).not_to be_valid
      expect(repository.errors[:installation]).to be_present
    end

    it "richiede environment di mapping dichiarati dal progetto" do
      repository = build(:github_repository)
      undeclared = create(:environment, organization: repository.project.organization)
      repository.production_environment = undeclared

      expect(repository).not_to be_valid
    end
  end

  describe "#html_url" do
    it "costruisce l'URL pubblico del repository da full_name" do
      repository = build(:github_repository, full_name: "bussolabs/closeyourit-rails")
      expect(repository.html_url).to eq("https://github.com/bussolabs/closeyourit-rails")
    end
  end

  describe "#target_environment_code" do
    let(:repository) { build(:github_repository, :with_env_mapping) }

    it "restituisce il code production per un tag stabile" do
      expect(repository.target_environment_code(stable: true)).to eq("production")
    end

    it "restituisce il code staging per un tag pre-release" do
      expect(repository.target_environment_code(stable: false)).to eq("staging")
    end

    it "restituisce nil quando il lato non è mappato" do
      repository.staging_environment = nil
      expect(repository.target_environment_code(stable: false)).to be_nil
    end
  end
end
