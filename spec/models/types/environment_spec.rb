# frozen_string_literal: true

require "rails_helper"

RSpec.describe Types::Environment, type: :model do
  describe "factory" do
    it "produce un environment valida" do
      expect(build(:environment)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede code" do
      expect(build(:environment, code: nil)).not_to be_valid
    end

    it "richiede label" do
      expect(build(:environment, label: nil)).not_to be_valid
    end

    it "richiede color" do
      expect(build(:environment, color: nil)).not_to be_valid
    end

    it "normalizza il code (downcase + underscore)" do
      expect(create(:environment, code: "  Production  ").code).to eq("production")
    end

    it "rifiuta un code con formato invalido" do
      expect(build(:environment, code: "1web")).not_to be_valid
    end
  end

  describe "unicità code per organizzazione" do
    it "rifiuta code duplicato nella stessa org" do
      org = create(:organization)
      create(:environment, organization: org, code: "production")
      expect(build(:environment, organization: org, code: "production")).not_to be_valid
    end

    it "permette lo stesso code in org diverse" do
      create(:environment, organization: create(:organization), code: "production")
      expect(build(:environment, organization: create(:organization), code: "production")).to be_valid
    end
  end

  describe "scope" do
    it ".active esclude le non attive" do
      org = create(:organization)
      active = create(:environment, organization: org, active: true)
      create(:environment, organization: org, active: false)
      expect(described_class.active).to contain_exactly(active)
    end

    it ".ordered ordina per position poi label" do
      org = create(:organization)
      second = create(:environment, organization: org, position: 2)
      first = create(:environment, organization: org, position: 1)
      expect(described_class.ordered.to_a).to eq([ first, second ])
    end
  end

  describe "dependent: :restrict_with_error" do
    it "blocca la cancellazione se usato da un progetto" do
      env = create(:environment)
      project = create(:project, organization: env.organization)
      project.environments << env
      expect(env.destroy).to be(false)
      expect(env.errors[:base]).to be_present
    end
  end
end
