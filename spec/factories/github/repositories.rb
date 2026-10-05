# frozen_string_literal: true

FactoryBot.define do
  factory :github_repository, class: "Github::Repository" do
    project { create(:project) }
    # Installazione della STESSA org del progetto (integrità tenant sul model).
    installation do
      project.organization.github_installation || create(:github_installation, organization: project.organization)
    end
    sequence(:repo_id) { |n| 5_000_000 + n }
    sequence(:full_name) { |n| "bussolabs/repo-#{n}" }
    default_branch { "main" }
    sync_enabled { true }
    tag_binding_enabled { true }
    autoclose_on_merge { false }

    # Mapping stabilità→environment con environment DICHIARATI dal progetto.
    trait :with_env_mapping do
      after(:build) do |repo|
        project = repo.project
        prod = create(:environment, organization: project.organization, code: "production")
        stg  = create(:environment, organization: project.organization, code: "staging")
        project.environments << prod
        project.environments << stg
        repo.production_environment = prod
        repo.staging_environment = stg
      end
    end
  end
end
