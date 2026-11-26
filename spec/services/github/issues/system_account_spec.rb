# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the organization's GitHub account is created once and sees the projects it carries.
RSpec.describe Github::Issues::SystemAccount do
  let(:repository) { create(:github_repository, issue_sync: :all_issues) }

  def sign = described_class.call(installation: repository.installation, project: repository.project)

  it "is created once and reused" do
    first = sign.value

    expect(sign.value).to eq(first)
    expect(first.name).to eq("GitHub")
    expect(repository.installation.reload.system_account).to eq(first)
  end

  it "an account that cannot be created is an error, and nothing is kept" do
    failure = Result.err(AppError.new("no", code: "R422-TEST-001"))
    repository
    allow(Connections::SetMemberAccess).to receive(:call).and_return(failure)

    expect do
      expect(sign.error).to eq(failure.error)
    end.not_to change(Accounts::Account, :count)
    expect(repository.installation.reload.system_account).to be_nil
  end
end
