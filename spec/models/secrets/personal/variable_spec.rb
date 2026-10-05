# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Variable do
  describe "validazioni" do
    it "richiede un nome" do
      variable = build(:personal_secret_variable, name: "")
      expect(variable).not_to be_valid
      expect(variable.errors[:name]).to be_present
    end

    it "normalizza il nome in UPPER_SNAKE" do
      variable = create(:personal_secret_variable, name: "  api_key ")
      expect(variable.name).to eq("API_KEY")
    end

    it "rifiuta un nome fuori formato" do
      variable = build(:personal_secret_variable, name: "1INVALID")
      expect(variable).not_to be_valid
      expect(variable.errors[:name]).to be_present
    end

    it "ammette un nome con prefisso GITHUB_ (nessun ban: il personale non si sincronizza)" do
      variable = build(:personal_secret_variable, name: "GITHUB_TOKEN")
      expect(variable).to be_valid
    end

    it "impone l'unicità del nome per [account, organization]" do
      existing = create(:personal_secret_variable, name: "API_KEY")
      dup = build(:personal_secret_variable, account: existing.account,
                                             organization: existing.organization, name: "API_KEY")
      expect(dup).not_to be_valid
    end

    it "ammette lo stesso nome in un'altra organizzazione dello stesso account" do
      existing = create(:personal_secret_variable, name: "API_KEY")
      twin = build(:personal_secret_variable, account: existing.account,
                                              organization: create(:organization), name: "API_KEY")
      expect(twin).to be_valid
    end

    it "ammette lo stesso nome per un altro account nella stessa organizzazione" do
      existing = create(:personal_secret_variable, name: "API_KEY")
      twin = build(:personal_secret_variable, account: create(:account),
                                              organization: existing.organization, name: "API_KEY")
      expect(twin).to be_valid
    end
  end

  describe "cifratura del valore" do
    it "fa il roundtrip del plaintext e non lo scrive in chiaro in colonna" do
      variable = create(:personal_secret_variable, value: "super-secret")
      expect(variable.reload.value).to eq("super-secret")

      raw = described_class.connection.select_value(
        "SELECT value FROM secrets_personal_variables WHERE id = '#{variable.id}'"
      )
      expect(raw).not_to include("super-secret")
    end
  end

  describe "attr_readonly" do
    it "non riassegna organization_id dopo la creazione" do
      variable = create(:personal_secret_variable)
      other_org = create(:organization)
      expect { variable.update(organization_id: other_org.id) }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(variable.reload.organization_id).not_to eq(other_org.id)
    end
  end

  describe ".for" do
    it "ritorna solo i secret dell'account nell'org" do
      mine = create(:personal_secret_variable)
      create(:personal_secret_variable) # altro account/org

      scope = described_class.for(account: mine.account, organization: mine.organization)
      expect(scope).to contain_exactly(mine)
    end
  end
end
