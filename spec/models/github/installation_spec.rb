# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Installation, type: :model do
  it "la factory produce un record valido" do
    expect(build(:github_installation)).to be_valid
  end

  describe "unicità" do
    it "ammette una sola installazione per organizzazione" do
      installation = create(:github_installation)
      duplicate = build(:github_installation, organization: installation.organization)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:organization_id]).to be_present
    end

    it "richiede installation_id univoco" do
      installation = create(:github_installation)
      duplicate = build(:github_installation, installation_id: installation.installation_id)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:installation_id]).to be_present
    end
  end

  it "richiede account_login" do
    expect(build(:github_installation, account_login: nil)).not_to be_valid
  end
end
