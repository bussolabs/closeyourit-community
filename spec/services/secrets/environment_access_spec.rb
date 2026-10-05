# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::EnvironmentAccess do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:other_project) { create(:project, organization:) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :member) }

  before do
    %w[development staging production].each do |code|
      environment = create(:environment, organization:, code:)
      project.environments << environment
      other_project.environments << environment
    end
  end

  def access(target = project) = described_class.new(account:, project: target)

  describe ".for_projects" do
    it "preserves project override precedence in batch reports" do
      membership.update!(secret_environment_codes: [ "staging" ])
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "production" ])

      policies = described_class.for_projects(account:, projects: [ project, other_project ])

      expect(policies.fetch(project.id).allowed?("production")).to be(true)
      expect(policies.fetch(project.id).allowed?("staging")).to be(false)
      expect(policies.fetch(other_project.id).allowed?("production")).to be(false)
      expect(policies.fetch(other_project.id).allowed?("staging")).to be(true)
    end

    it "returns no policies when there are no visible projects" do
      expect(described_class.for_projects(account:, projects: [])).to eq({})
    end
  end

  describe "nessuna restrizione" do
    it "consente ogni ambiente e non è ristretto" do
      expect(access).not_to be_restricted
      expect(access.allowed?("production")).to be(true)
      expect(access.allowed_codes).to contain_exactly("development", "staging", "production")
    end

    it "consente ogni ambiente anche senza membership nell'org (account esterno già filtrato a monte)" do
      membership.destroy!

      expect(access.allowed?("production")).to be(true)
    end
  end

  describe "restrizione org-wide" do
    before { membership.update!(secret_environment_codes: %w[development staging]) }

    it "consente gli ambienti in lista e nega gli altri" do
      expect(access).to be_restricted
      expect(access.allowed?("staging")).to be(true)
      expect(access.allowed?("production")).to be(false)
    end

    it "vale su tutti i progetti dell'organizzazione" do
      expect(access(other_project).allowed?("production")).to be(false)
    end

    it "allowed_codes elenca solo gli ambienti consentiti del progetto" do
      expect(access.allowed_codes).to contain_exactly("development", "staging")
    end
  end

  describe "override per-progetto" do
    before { membership.update!(secret_environment_codes: %w[development staging]) }

    it "allarga l'accesso SOLO sul progetto scelto" do
      create(:account_secret_access, account:, project:, organization:,
                                     environment_codes: %w[development staging production])

      expect(access.allowed?("production")).to be(true)
      expect(access(other_project).allowed?("production")).to be(false)
    end

    it "restringe anche quando l'org-wide è libero" do
      membership.update!(secret_environment_codes: [])
      create(:account_secret_access, account:, project:, organization:, environment_codes: %w[development])

      expect(access).to be_restricted
      expect(access.allowed?("development")).to be(true)
      expect(access.allowed?("production")).to be(false)
      expect(access(other_project).allowed?("production")).to be(true)
    end

    it "l'override di un altro account non tocca questo" do
      create(:account_secret_access, account: create(:account), project:, organization:,
                                     environment_codes: %w[production])

      expect(access.allowed?("production")).to be(false)
    end

    it "una riga con allow-list vuota non è un override: torna a valere l'org-wide" do
      create(:account_secret_access, account:, project:, organization:, environment_codes: [])

      expect(access.allowed?("staging")).to be(true)
      expect(access.allowed?("production")).to be(false)
    end
  end

  it "un code sconosciuto al progetto non entra mai in allowed_codes" do
    membership.update!(secret_environment_codes: %w[staging preview])

    expect(access.allowed_codes).to contain_exactly("staging")
  end

  it "confronta i code normalizzati (maiuscole e spazi non aggirano il confine)" do
    membership.update!(secret_environment_codes: %w[staging])

    expect(access.allowed?(" Staging ")).to be(true)
    expect(access.allowed?("PRODUCTION")).to be(false)
  end

  it "un ambiente nil è negato quando la restrizione è attiva" do
    membership.update!(secret_environment_codes: %w[staging])

    expect(access.allowed?(nil)).to be(false)
  end
end
