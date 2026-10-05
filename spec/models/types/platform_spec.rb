# frozen_string_literal: true

require "rails_helper"

RSpec.describe Types::Platform, type: :model do
  describe "factory" do
    it "produce una piattaforma valida" do
      expect(build(:platform)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede code" do
      expect(build(:platform, code: nil)).not_to be_valid
    end

    it "richiede label" do
      expect(build(:platform, label: nil)).not_to be_valid
    end

    it "richiede color" do
      expect(build(:platform, color: nil)).not_to be_valid
    end

    it "normalizza il code (downcase + underscore)" do
      expect(create(:platform, code: "  iOS  ").code).to eq("ios")
    end

    it "rifiuta un code con formato invalido" do
      expect(build(:platform, code: "1web")).not_to be_valid
    end
  end

  describe "unicità code per organizzazione" do
    it "rifiuta code duplicato nella stessa org" do
      org = create(:organization)
      create(:platform, organization: org, code: "ios")
      expect(build(:platform, organization: org, code: "ios")).not_to be_valid
    end

    it "permette lo stesso code in org diverse" do
      create(:platform, organization: create(:organization), code: "ios")
      expect(build(:platform, organization: create(:organization), code: "ios")).to be_valid
    end
  end

  describe "scope" do
    it ".active esclude le non attive" do
      org = create(:organization)
      active = create(:platform, organization: org, active: true)
      create(:platform, organization: org, active: false)
      expect(described_class.active).to contain_exactly(active)
    end

    it ".ordered ordina per position poi label" do
      org = create(:organization)
      second = create(:platform, organization: org, position: 2)
      first = create(:platform, organization: org, position: 1)
      expect(described_class.ordered.to_a).to eq([ first, second ])
    end
  end

  describe "capability uptime (supports_uptime)" do
    it "default false (opt-in dalla CRUD)" do
      expect(build(:platform).supports_uptime).to be(false)
    end

    it "il trait :uptime_capable la abilita" do
      expect(build(:platform, :uptime_capable).supports_uptime).to be(true)
    end

    it ".uptime_capable include solo le piattaforme con supports_uptime" do
      org = create(:organization)
      web = create(:platform, :uptime_capable, organization: org)
      create(:platform, organization: org) # nativa → supports_uptime false
      expect(described_class.uptime_capable).to contain_exactly(web)
    end
  end

  describe "dependent: :restrict_with_error" do
    it "blocca la cancellazione se usata da un progetto" do
      platform = create(:platform)
      project = create(:project, organization: platform.organization)
      project.platforms << platform
      expect(platform.destroy).to be(false)
      expect(platform.errors[:base]).to be_present
    end
  end
end
