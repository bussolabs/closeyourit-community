# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::SetSecretAccess do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:membership) { create(:membership, account:, organization:, role: :member) }
  let(:project) { create(:project, organization:) }

  before do
    %w[development staging production].each { |code| create(:environment, organization:, code:) }
  end

  def per_project_codes(target = project)
    Connections::AccountSecretAccess.find_by(account:, project: target)&.environment_codes
  end

  describe "allow-list org-wide" do
    it "salva solo i code che esistono davvero nell'organizzazione (anti-lockout)" do
      result = described_class.call(membership:, org_wide_codes: [ "staging", "inesistente" ], per_project: {})

      expect(result).to be_ok
      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end

    it "una lista vuota toglie la restrizione" do
      membership.update!(secret_environment_codes: [ "staging" ])

      described_class.call(membership:, org_wide_codes: [], per_project: {})

      expect(membership.reload.secret_environment_codes).to eq([])
    end

    it "normalizza spazi e maiuscole prima di confrontare" do
      described_class.call(membership:, org_wide_codes: [ " Staging " ], per_project: {})

      expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    end
  end

  describe "override per-progetto" do
    it "crea la riga di override coi soli code reali dell'organizzazione" do
      described_class.call(membership:, org_wide_codes: [ "staging" ],
                           per_project: { project.id => [ "staging", "production", "inesistente" ] })

      expect(per_project_codes).to eq(%w[staging production])
    end

    it "aggiorna un override esistente" do
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "production" ])

      described_class.call(membership:, org_wide_codes: [], per_project: { project.id => [ "development" ] })

      expect(per_project_codes).to eq([ "development" ])
    end

    it "una lista vuota rimuove l'override invece di salvarlo vuoto" do
      create(:account_secret_access, account:, project:, organization:, environment_codes: [ "production" ])

      described_class.call(membership:, org_wide_codes: [], per_project: { project.id => [] })

      expect(Connections::AccountSecretAccess.where(account:, project:)).not_to exist
    end

    it "un progetto NON toccato dai parametri resta com'è" do
      other = create(:project, organization:)
      create(:account_secret_access, account:, project: other, organization:, environment_codes: [ "production" ])

      described_class.call(membership:, org_wide_codes: [], per_project: { project.id => [ "staging" ] })

      expect(per_project_codes(other)).to eq([ "production" ])
    end

    it "ignora un progetto di un'altra organizzazione (anti-BOLA)" do
      foreign = create(:project)

      result = described_class.call(membership:, org_wide_codes: [], per_project: { foreign.id => [ "staging" ] })

      expect(result).to be_ok
      expect(Connections::AccountSecretAccess.where(project: foreign)).not_to exist
    end

    it "ignora un id di progetto inesistente" do
      result = described_class.call(membership:, org_wide_codes: [], per_project: { SecureRandom.uuid => [ "staging" ] })

      expect(result).to be_ok
      expect(Connections::AccountSecretAccess.count).to eq(0)
    end
  end

  it "accetta i parametri così come arrivano dal form (chiavi stringa, valori array)" do
    described_class.call(membership:, org_wide_codes: [ "", "staging" ],
                         per_project: { project.id.to_s => [ "", "production" ] })

    expect(membership.reload.secret_environment_codes).to eq([ "staging" ])
    expect(per_project_codes).to eq([ "production" ])
  end

  it "è atomico: se l'override fallisce, l'allow-list org-wide non resta salvata" do
    allow(Connections::AccountSecretAccess).to receive(:find_or_initialize_by).and_raise(ActiveRecord::RecordInvalid.new(Connections::AccountSecretAccess.new))

    result = described_class.call(membership:, org_wide_codes: [ "staging" ],
                                  per_project: { project.id => [ "production" ] })

    expect(result).to be_err
    expect(membership.reload.secret_environment_codes).to eq([])
  end
end
