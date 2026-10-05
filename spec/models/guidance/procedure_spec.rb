# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guidance::Procedure, type: :model do
  describe "factory" do
    it "è valida di default" do
      expect(build(:guidance_procedure)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede il content" do
      expect(build(:guidance_procedure, content: "   ")).not_to be_valid
    end

    it "richiede la key" do
      expect(build(:guidance_procedure, key: nil)).not_to be_valid
    end

    it "rifiuta un owner_type fuori dalla whitelist" do
      procedure = build(:guidance_procedure)
      procedure.owner_type = "Accounts::Account"
      expect(procedure).not_to be_valid
      expect(procedure.errors[:owner_type]).to be_present
    end

    it "impedisce due procedure con la stessa key sullo stesso owner" do
      project = create(:project)
      create(:guidance_procedure, owner: project, key: "setup")
      duplicate = build(:guidance_procedure, owner: project, key: "setup")
      expect(duplicate).not_to be_valid
    end
  end

  describe "modalità" do
    it "espone i modi di applicazione" do
      expect(described_class.application_modes.keys).to contain_exactly("inherit", "replace", "disable")
    end

    it "espone le strategie di merge" do
      expect(described_class.merge_strategies.keys).to contain_exactly("override", "append")
    end
  end

  describe "integrità tenant" do
    it "rifiuta un'organizzazione diversa da quella dell'owner" do
      project = create(:project)
      other_org = create(:organization)
      procedure = build(:guidance_procedure, owner: project, organization: other_org)
      expect(procedure).not_to be_valid
      expect(procedure.errors[:organization]).to be_present
    end
  end
end
