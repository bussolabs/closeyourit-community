# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Version do
  it "impone l'unicità di [variable, number]" do
    variable = create(:personal_secret_variable)
    create(:personal_secret_version, variable:, number: 1)
    dup = build(:personal_secret_version, variable:, number: 1)
    expect(dup).not_to be_valid
  end

  it "ammette lo stesso number su variabili diverse" do
    create(:personal_secret_version, number: 1)
    twin = build(:personal_secret_version, number: 1)
    expect(twin).to be_valid
  end

  it "cifra il valore at-rest" do
    version = create(:personal_secret_version, value: "snap-secret")
    raw = described_class.connection.select_value(
      "SELECT value FROM secrets_personal_versions WHERE id = '#{version.id}'"
    )
    expect(raw).not_to include("snap-secret")
    expect(version.reload.value).to eq("snap-secret")
  end
end
