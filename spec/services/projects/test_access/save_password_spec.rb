# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::TestAccess::SavePassword do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }

  def declare_staging
    create(:environment, organization:, code: "staging", label: "Staging").tap { |environment| project.environments << environment }
  end

  it "stores the password encrypted in the staging vault and says it is set" do
    staging = declare_staging
    expect(described_class.set?(project)).to be(false)

    result = described_class.call(project:, password: "S3cret-pass", actor:)

    expect(result).to be_ok
    variable = project.secret_variables.find_by!(environment: staging, name: "TEST_ACCESS_PASSWORD")
    expect(variable.value).to eq("S3cret-pass")
    expect(variable.value_before_type_cast).not_to include("S3cret-pass")
    expect(described_class.set?(project)).to be(true)
  end

  it "replaces the password and keeps the history" do
    declare_staging
    described_class.call(project:, password: "first-pass", actor:)

    described_class.call(project:, password: "second-pass", actor:)

    variable = project.secret_variables.find_by!(name: "TEST_ACCESS_PASSWORD")
    expect(variable.value).to eq("second-pass")
    expect(variable.versions.count).to eq(2)
  end

  it "refuses when the project has no staging environment" do
    result = described_class.call(project:, password: "S3cret-pass", actor:)

    expect(result).not_to be_ok
    expect(result.error.code).to eq("R422-TEST-ACCESS-001")
    expect(project.secret_variables.count).to eq(0)
  end
end
