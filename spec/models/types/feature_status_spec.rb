# frozen_string_literal: true

require "rails_helper"

RSpec.describe Types::FeatureStatus, type: :model do
  describe "factory" do
    it "produce uno stato valido" do
      expect(build(:feature_status)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede code" do
      expect(build(:feature_status, code: nil)).not_to be_valid
    end

    it "richiede label" do
      expect(build(:feature_status, label: nil)).not_to be_valid
    end

    it "richiede color" do
      expect(build(:feature_status, color: nil)).not_to be_valid
    end

    it "normalizza il code (downcase + underscore)" do
      expect(create(:feature_status, code: "  In Development  ").code).to eq("in_development")
    end

    it "rifiuta un code con formato invalido" do
      expect(build(:feature_status, code: "2fa")).not_to be_valid
    end
  end

  describe "unicità code per organizzazione" do
    it "rifiuta code duplicato nella stessa org" do
      org = create(:organization)
      create(:feature_status, organization: org, code: "available")
      expect(build(:feature_status, organization: org, code: "available")).not_to be_valid
    end

    it "permette lo stesso code in org diverse" do
      create(:feature_status, organization: create(:organization), code: "available")
      expect(build(:feature_status, organization: create(:organization), code: "available")).to be_valid
    end
  end

  describe "scope" do
    it ".active esclude i non attivi" do
      org = create(:organization)
      active = create(:feature_status, organization: org)
      create(:feature_status, :inactive, organization: org)
      expect(described_class.where(organization: org).active).to contain_exactly(active)
    end

    it ".ordered ordina per position poi label" do
      org = create(:organization)
      second = create(:feature_status, organization: org, position: 2)
      first = create(:feature_status, organization: org, position: 1)
      expect(described_class.where(organization: org).ordered.to_a).to eq([ first, second ])
    end
  end

  describe "#released?" do
    it "è vero per available" do
      expect(build(:feature_status, :available)).to be_released
    end

    it "è vero per deprecated" do
      expect(build(:feature_status, :deprecated)).to be_released
    end

    it "è falso per in_development" do
      expect(build(:feature_status, :in_development)).not_to be_released
    end

    it "è falso per not_applicable" do
      expect(build(:feature_status, :not_applicable)).not_to be_released
    end
  end

  describe "cancellazione" do
    it "blocca la cancellazione di uno stato usato da una cella" do
      cell = create(:feature_platform)
      expect(cell.status.destroy).to be(false)
    end
  end
end
