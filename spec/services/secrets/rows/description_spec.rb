# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Rows::Save do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization, code: "production") }
  let!(:link) { create(:project_environment, project:, environment:) }
  let!(:original) do
    described_class.call(project:, name: "TOKEN", cells: [ { environment:, value: "fixture-value", description: "Before" } ])
                   .value.submissions.first.variable
  end

  it "preserves the value, rotation time and versions on a description edit" do
    rotated_at = original.rotated_at
    expect do
      result = described_class.call(project:, name: "TOKEN", cells: [ { environment:, value: "", description: "After" } ])
      expect(result).to be_ok
    end.not_to change { original.versions.count }
    expect(original.reload.description).to eq("After")
    expect(original.value).to eq("fixture-value")
    expect(original.rotated_at).to eq(rotated_at)
  end

  it "rejects a protected description edit instead of silently discarding it" do
    allow(Secrets::ChangeRequest).to receive(:description_requests_supported?).and_return(false)
    project.update!(secret_approval_enabled: true)
    link.update!(approval_required: true)
    result = described_class.call(project:, name: "TOKEN", cells: [ { environment:, value: "", description: "After" } ])
    expect(result).to be_err
    expect(result.error.message).to eq(I18n.t("member.review_fixes.secret_protected_description"))
    expect(original.reload.description).to eq("Before")
    expect(Secrets::ChangeRequest.where(project:)).to be_empty
  end

  it "submits only the proposed description for approval without capturing the value" do
    project.update!(secret_approval_enabled: true)
    link.update!(approval_required: true)
    result = described_class.call(project:, name: "TOKEN", cells: [ { environment:, value: "", description: "After" } ])

    expect(result).to be_ok
    request = result.value.submissions.first.change_request
    expect(request).to be_description_only_change
    expect(request.value).to be_nil
    expect(request.proposed_description).to eq("After")
    expect(original.reload.description).to eq("Before")
  end
end
