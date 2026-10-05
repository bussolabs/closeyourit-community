# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::CtoProjects do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:visible_projects) { organization.projects }

  def keys = described_class.scope(account:, organization:, visible_projects:).pluck(:key)

  describe "chi non è CTO di niente" do
    let!(:senza_cto) { create(:project, organization:) }
    let!(:altrui) { create(:project, organization:) }

    before { altrui.update_column(:cto_id, create(:account).id) }

    it "non risponde di nessun progetto" do
      expect(keys).to be_empty
      expect(described_class.any?(account:, organization:, visible_projects:)).to be(false)
    end
  end

  describe "CTO di un progetto" do
    let!(:mio) { create(:project, organization:) }
    let!(:senza_cto) { create(:project, organization:) }

    before { mio.update_column(:cto_id, account.id) }

    it "risponde del solo progetto di cui è CTO, non di quelli senza CTO" do
      expect(keys).to contain_exactly(mio.key)
      expect(described_class.any?(account:, organization:, visible_projects:)).to be(true)
    end
  end

  describe "CTO dell'organizzazione" do
    let!(:senza_cto) { create(:project, organization:) }
    let!(:altrui) { create(:project, organization:) }

    before do
      altrui.update_column(:cto_id, create(:account).id)
      organization.update_column(:cto_id, account.id)
    end

    it "risponde dei progetti senza CTO proprio, mai di quelli affidati a qualcun altro" do
      expect(keys).to contain_exactly(senza_cto.key)
    end

    it "risponde anche dei progetti di cui è CTO esplicito" do
      suo = create(:project, organization:)
      suo.update_column(:cto_id, account.id)

      expect(keys).to contain_exactly(senza_cto.key, suo.key)
    end
  end

  describe "senza progetti visibili" do
    before { organization.update_column(:cto_id, account.id) }

    it "torna vuoto invece di allargarsi a tutta l'organizzazione" do
      create(:project, organization:)

      expect(described_class.scope(account:, organization:, visible_projects: Projects::Project.none)).to be_empty
    end
  end
end
