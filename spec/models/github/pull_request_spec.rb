# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::PullRequest, type: :model do
  it "la factory produce un record valido" do
    expect(build(:github_pull_request)).to be_valid
  end

  it "il numero è univoco per repository" do
    pull = create(:github_pull_request)
    duplicate = build(:github_pull_request, repository: pull.repository, number: pull.number)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:number]).to be_present
  end

  it "richiede title e html_url" do
    expect(build(:github_pull_request, title: nil)).not_to be_valid
    expect(build(:github_pull_request, html_url: nil)).not_to be_valid
  end

  it "espone lo stato via enum con prefisso" do
    expect(build(:github_pull_request, state: :merged)).to be_state_merged
    expect(build(:github_pull_request, state: :open)).to be_state_open
  end

  it "il ticket è opzionale" do
    expect(build(:github_pull_request, ticket: nil)).to be_valid
  end
end
