# frozen_string_literal: true

require "rails_helper"

# CYRA-422 — chi può LEGGERE in chiaro i secret, risolto dalle membership reali (nome + ruolo) per il
# pannello «Chi può vedere questi segreti». Deve combaciare col gate applicato davvero: per il progetto
# secrets.read OR secrets.manage (ProjectSecretsController#require_secrets_read — "manage implica read");
# per l'organizzazione shared_secrets.manage. Gli scenari ancorano la PARITÀ con Authorization::Resolver
# (owner → override personale allow/deny che batte i ruoli → ruoli diretti/team collegati allo scope),
# perché qui la stessa gerarchia è valutata in batch invece che col resolver per-account.
RSpec.describe Secrets::Readers do
  let(:org) { create(:organization) }

  def member!(account, role = :member) = create(:membership, account: account, organization: org, role: role)

  def role_with(name, *keys)
    role = create(:role, organization: org, name: name)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  describe ".for_project" do
    let(:project) { create(:project, organization: org) }

    it "include sempre l'owner, con nome e ruolo, anche senza link al progetto" do
      owner = create(:account, name: "Ada Owner")
      member!(owner, :owner)

      readers = described_class.for_project(project)

      expect(readers.map(&:account)).to contain_exactly(owner)
      expect(readers.first.role).to eq(:owner)
    end

    it "esclude un membro senza alcun permesso sui secret" do
      plain = create(:account)
      member!(plain)
      create(:project_membership, account: plain, project: project)

      expect(described_class.for_project(project).map(&:account)).to be_empty
    end

    it "include chi ha l'override personale allow su secrets.read e vede il progetto" do
      reader = create(:account)
      member!(reader)
      create(:project_membership, account: reader, project: project)
      create(:account_permission, account: reader, organization: org, permission_key: "secrets.read", effect: :allow)

      expect(described_class.for_project(project).map(&:account)).to include(reader)
    end

    it "esclude chi ha l'override allow ma NON vede il progetto (scope non visibile)" do
      reader = create(:account)
      member!(reader)
      create(:account_permission, account: reader, organization: org, permission_key: "secrets.read", effect: :allow)

      expect(described_class.for_project(project).map(&:account)).to be_empty
    end

    # CYRA-721 — gestire non è leggere: chi ha solo secrets.manage cambia i valori ma non li vede in
    # chiaro, quindi non appartiene alla lista di «chi può vedere questi segreti». Prima compariva, e il
    # pannello prometteva a chi legge una platea più larga di quella vera.
    it "esclude chi ha solo secrets.manage: gestire non apre il valore in chiaro" do
      person = create(:account)
      member!(person)
      create(:project_membership, account: person, project: project)
      create(:account_role, account: person, organization: org, role: role_with("Maintainer", "secrets.manage"))

      expect(described_class.for_project(project).map(&:account)).to be_empty
    end

    it "esclude via override deny anche quando un ruolo concederebbe la stessa chiave" do
      person = create(:account)
      member!(person)
      create(:project_membership, account: person, project: project)
      create(:account_role, account: person, organization: org, role: role_with("Reader", "secrets.read"))
      create(:account_permission, account: person, organization: org, permission_key: "secrets.read", effect: :deny)

      expect(described_class.for_project(project).map(&:account)).to be_empty
    end

    it "include chi ha il ruolo (diretto) con secrets.read e link personale al progetto" do
      person = create(:account)
      member!(person)
      create(:project_membership, account: person, project: project)
      create(:account_role, account: person, organization: org, role: role_with("Reader", "secrets.read"))

      expect(described_class.for_project(project).map(&:account)).to include(person)
    end

    it "esclude il ruolo diretto con la chiave se l'account NON è collegato allo scope" do
      person = create(:account)
      member!(person)
      create(:account_role, account: person, organization: org, role: role_with("Reader", "secrets.read"))

      expect(described_class.for_project(project).map(&:account)).to be_empty
    end

    it "include i membri di un team con ruolo secrets.read collegato al progetto" do
      person = create(:account)
      member!(person)
      team = create(:team, organization: org)
      create(:team_membership, account: person, team: team)
      create(:team_role, team: team, role: role_with("Reader", "secrets.read"))
      create(:team_project_access, team: team, project: project)

      expect(described_class.for_project(project).map(&:account)).to include(person)
    end

    it "esclude i membri di un team con la chiave se il team NON è collegato al progetto (no leak)" do
      person = create(:account)
      member!(person)
      team = create(:team, organization: org)
      create(:team_membership, account: person, team: team)
      create(:team_role, team: team, role: role_with("Reader", "secrets.read"))

      expect(described_class.for_project(project).map(&:account)).to be_empty
    end

    it "ordina l'owner per primo, poi per nome" do
      owner = create(:account, name: "Zoe Owner")
      member!(owner, :owner)
      bea = create(:account, name: "Bea Reader")
      ada = create(:account, name: "Ada Reader")
      [ bea, ada ].each do |a|
        member!(a)
        create(:project_membership, account: a, project: project)
        create(:account_permission, account: a, organization: org, permission_key: "secrets.read", effect: :allow)
      end

      names = described_class.for_project(project).map { |r| r.account.name }
      expect(names).to eq([ "Zoe Owner", "Ada Reader", "Bea Reader" ])
    end
  end

  describe ".for_project_files" do
    let(:project) { create(:project, organization: org) }

    it "usa il gate secret_files.read/manage, non secrets.read" do
      only_env = create(:account)
      member!(only_env)
      create(:project_membership, account: only_env, project: project)
      create(:account_permission, account: only_env, organization: org, permission_key: "secrets.read", effect: :allow)

      files_reader = create(:account)
      member!(files_reader)
      create(:project_membership, account: files_reader, project: project)
      create(:account_permission, account: files_reader, organization: org, permission_key: "secret_files.read", effect: :allow)

      accounts = described_class.for_project_files(project).map(&:account)
      expect(accounts).to include(files_reader)
      expect(accounts).not_to include(only_env)
    end
  end

  describe ".for_organization" do
    it "include owner e chi ha shared_secrets.manage (override o ruolo org-level), esclude gli altri" do
      owner = create(:account, name: "Owner")
      member!(owner, :owner)

      by_override = create(:account, name: "Override")
      member!(by_override)
      create(:account_permission, account: by_override, organization: org, permission_key: "shared_secrets.manage", effect: :allow)

      by_role = create(:account, name: "Role")
      member!(by_role)
      create(:account_role, account: by_role, organization: org, role: role_with("SharedManager", "shared_secrets.manage"))

      plain = create(:account, name: "Plain")
      member!(plain)

      accounts = described_class.for_organization(org).map(&:account)
      expect(accounts).to contain_exactly(owner, by_override, by_role)
    end
  end
end
