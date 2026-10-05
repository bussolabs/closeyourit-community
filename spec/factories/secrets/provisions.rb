# frozen_string_literal: true

FactoryBot.define do
  factory :secret_provision, class: "Secrets::Provision" do
    organization { create(:organization) }
    source_project { create(:project, organization:) }
    destination_project { source_project }
    source_environment do
      source_project.environments.first || create(:environment, organization:).tap do |environment|
        source_project.environments << environment
      end
    end
    destination_environment { source_environment }
    token { create(:project_token, project: source_project, environment: source_environment) }
    secret_variable do
      create(:secret_variable, project: destination_project, organization:,
                               environment: destination_environment)
    end
    created_by { nil }
    secret_name { secret_variable.name }
    status { :pending_sync }
    sequence(:idempotency_key) { |n| "provision-#{n}" }
    request_fingerprint { Digest::SHA256.hexdigest(idempotency_key) }
    sync_github { true }
  end
end
