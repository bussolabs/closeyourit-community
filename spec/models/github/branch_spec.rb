# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Branch, type: :model do
  it "la factory produce un record valido" do
    expect(build(:github_branch)).to be_valid
  end

  it "richiede un nome" do
    expect(build(:github_branch, name: nil)).not_to be_valid
  end

  it "il nome è univoco per repository" do
    branch = create(:github_branch)
    duplicate = build(:github_branch, repository: branch.repository, name: branch.name)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:name]).to be_present
  end

  it "il ticket è opzionale" do
    expect(build(:github_branch, ticket: nil)).to be_valid
  end
end
