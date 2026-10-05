# frozen_string_literal: true

FactoryBot.define do
  # Anomalia del Vault persistita (CYRA-409). L'ambiente deve appartenere alla stessa org del progetto:
  # after(:build) lo garantisce quando non è passato esplicitamente, come fa il factory di secret_variable.
  factory :secret_health_anomaly, class: "Secrets::HealthAnomaly" do
    project { create(:project) }
    organization { project&.organization }
    kind { :drift_hole }
    sequence(:secret_name) { |n| "SECRET_VAR_#{n}" }
    status { :open }
    first_seen_at { Time.current }
    last_seen_at { Time.current }

    after(:build) do |anomaly|
      next if anomaly.environment.present? || anomaly.project.blank?

      env = anomaly.project.environments.first ||
            create(:environment, organization: anomaly.project.organization)
      anomaly.environment = env
    end

    trait :empty_environment do
      kind { :empty_environment }
      secret_name { "" }
    end

    trait :broken_delegation do
      kind { :broken_delegation }
    end

    trait :acknowledged do
      status { :acknowledged }
      acknowledged_at { Time.current }
      association :acknowledged_by, factory: :account
      acknowledgement_reason { "Assenza voluta in questo ambiente." }
    end

    trait :resolved do
      status { :resolved }
      resolved_at { Time.current }
    end
  end
end
