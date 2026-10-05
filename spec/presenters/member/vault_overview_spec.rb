# frozen_string_literal: true

require "rails_helper"

# Presenter della landing del Vault (CYRA-135, Fase 1b): trasforma la overview da hub di link statici
# a cruscotto — conteggi per livello (progetto / organizzazione / personale) e ultime attivita.
RSpec.describe Member::VaultOverview do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  def overview
    described_class.new(organization: organization, account: account)
  end

  # CYRA-413: sotto ogni tipo della landing serve un conteggio ("quanti sono"), per livello.
  describe "#personal_secrets_count" do
    it "conta variabili e file personali dell'account nell'organizzazione, e nient'altro" do
      create(:personal_secret_variable, account: account, organization: organization)
      create(:personal_secret_asset, account: account, organization: organization)
      # Rumore: un altro account, o un'altra organizzazione, non deve entrare nel conteggio.
      create(:personal_secret_variable, account: create(:account), organization: organization)
      create(:personal_secret_variable, account: account, organization: create(:organization))

      expect(overview.personal_secrets_count).to eq(2)
    end
  end

  describe "#organization_secrets_count" do
    it "conta le variabili e i file dell'organizzazione (livello org), non quelli di progetto" do
      Secrets::Shared::Variable.create!(organization: organization, name: "SHARED_ONE")
      Secrets::Asset.create!(organization: organization, name: "org.p8", asset_type: "p8") # project nil = org
      project = create(:project, organization: organization)
      Secrets::Asset.create!(organization: organization, project: project, name: "proj.p8", asset_type: "p8")

      expect(overview.organization_secrets_count).to eq(2)
    end
  end
end
