# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::Github do
  let(:source) { create(:organization) }
  let(:destination) { create(:organization) }
  let(:project) { create(:project, organization: source) }
  let(:subject_) { Projects::Moves::Subject.new(project) }
  let!(:repository) { create(:github_repository, project:) }

  it "lists nothing for a project without a repository" do
    bare = Projects::Moves::Subject.new(create(:project, organization: source))
    expect(described_class.preview(bare)).to be_empty
  end

  it "previews the repository as detached: no stored list tells what the destination installation sees" do
    create(:github_installation, organization: destination)

    expect(described_class.preview(subject_))
      .to contain_exactly({ table: "github_repositories", count: 1 })
  end

  it "removes the link on apply, with its branches and pull requests" do
    create(:github_branch, repository:)

    described_class.apply!(subject_)

    expect(Github::Repository.exists?(repository.id)).to be(false)
    expect(Github::Branch.where(repository_id: repository.id)).to be_empty
  end

  context "with agent rows pointing to the repository" do
    let(:workflow) { create(:agent_workflow, organization: source) }
    let!(:candidate) do
      create(:agent_delivery_candidate, workflow:, attempt: create(:agent_attempt, workflow:, phase: "autopilot"), repository:)
    end

    before do
      Agents::ReleaseAssignment.create!(workflow:, github_repository: repository, execution_phase: "closer_staging",
                                        version: "1.0.0")
    end

    it "previews the delivery candidates set loose and the release assignments deleted" do
      expect(described_class.preview(subject_))
        .to contain_exactly({ table: "github_repositories", count: 1 },
                            { table: "agents_delivery_candidates", count: 1 },
                            { table: "agents_release_assignments", count: 1 })
    end

    it "nullifies the nullable link and deletes the rows that cannot lose it" do
      described_class.apply!(subject_)

      expect(Github::Repository.exists?(repository.id)).to be(false)
      expect(candidate.reload.repository_id).to be_nil
      expect(Agents::ReleaseAssignment.where(github_repository_id: repository.id)).to be_empty
    end
  end
end
