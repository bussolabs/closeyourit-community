# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Protected secret descriptions" do
  let(:project) { create(:project, secret_approval_enabled: true) }
  let(:environment) { create(:environment, organization: project.organization) }
  let!(:link) { create(:project_environment, project:, environment:, approval_required: true) }
  let(:requester) { create(:account) }
  let(:approver) { create(:account) }

  def submit(**attributes)
    Secrets::ChangeRequests::Submit.call(project:, environment:, actor: requester,
                                         name: "TEST_TOKEN", action: :set, **attributes)
  end

  def apply(request)
    Secrets::ChangeRequests::Approve.call(change_request: request, actor: approver)
  end

  def set_variable(value: "first", description: "Before")
    Secrets::Variables::Set.call(project:, environment:, name: "TEST_TOKEN", value:, description:).value
  end

  it "persists and applies a description alongside a new value" do
    result = submit(value: "fixture", description: "Purpose of the token")
    expect(result).to be_ok
    request = result.value.change_request
    expect(request.proposed_description).to eq("Purpose of the token")
    expect(apply(request)).to be_ok
    expect(project.secret_variables.find_by!(name: "TEST_TOKEN").description).to eq("Purpose of the token")
  end

  it "preserves a later rotation when approving a description-only change" do
    variable = set_variable
    request = submit(description_only: true, description: "After").value.change_request
    travel 1.hour do
      set_variable(value: "rotated", description: "Before")
    end
    rotation = variable.reload.rotated_at
    versions = variable.versions.count

    expect(apply(request)).to be_ok

    expect(variable.reload.description).to eq("After")
    expect(variable.value).to eq("rotated")
    expect(variable.rotated_at).to eq(rotation)
    expect(variable.versions.count).to eq(versions)
  end

  it "clears a description explicitly while nil preserves it" do
    variable = set_variable
    expect(apply(submit(value: "second").value.change_request)).to be_ok
    expect(variable.reload.description).to eq("Before")
    expect(apply(submit(description_only: true, description: "").value.change_request)).to be_ok
    expect(variable.reload.description).to eq("")
  end

  it "does not recreate a secret deleted while the description awaited approval" do
    variable = set_variable
    request = submit(description_only: true, description: "After").value.change_request
    variable.destroy!

    expect(apply(request)).to be_err
    expect(request.reload).to be_pending
    expect(project.secret_variables.reload).to be_empty
  end

  it "keeps the two-person decision rule" do
    set_variable
    request = submit(description_only: true, description: "After").value.change_request
    result = Secrets::ChangeRequests::Approve.call(change_request: request, actor: requester)
    expect(result).to be_err
    expect(request.reload).to be_pending
  end

  it "rejects inconsistent description-only requests" do
    expect(submit(description_only: true, description: nil)).to be_err
    expect(submit(description_only: true, description: "After", value: "unexpected")).to be_err
  end
end
