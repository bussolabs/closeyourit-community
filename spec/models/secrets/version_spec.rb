require "rails_helper"

RSpec.describe Secrets::Version, type: :model do
  it "la factory produce una versione valida" do
    expect(build(:secret_version)).to be_valid
  end

  it "number è unico per variabile" do
    existing = create(:secret_version)
    dup = build(:secret_version, secret_variable: existing.secret_variable, number: existing.number)
    expect(dup).not_to be_valid
  end

  it "cifra il valore at-rest (ciphertext in DB, decifrato dopo reload)" do
    version = create(:secret_version, value: "old-value")
    expect(version.reload.value).to eq("old-value")
    raw = described_class.connection.select_value(
      described_class.sanitize_sql_array([ "SELECT value FROM secrets_versions WHERE id = ?", version.id ])
    )
    expect(raw).not_to include("old-value")
  end

  describe ".ordered" do
    it "ordina per number decrescente" do
      variable = create(:secret_variable)
      v1 = create(:secret_version, secret_variable: variable, number: 1)
      v2 = create(:secret_version, secret_variable: variable, number: 2)
      expect(variable.versions.ordered.to_a).to eq([ v2, v1 ])
    end
  end
end
