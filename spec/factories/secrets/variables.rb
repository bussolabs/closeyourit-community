# frozen_string_literal: true

FactoryBot.define do
  # La variabile richiede un environment DICHIARATO dal progetto (vincolo subset, come project_token):
  # il progetto va creato e deve avere l'environment nel join. after(:build) lo garantisce.
  factory :secret_variable, class: "Secrets::Variable" do
    project { create(:project) }
    organization { project&.organization }
    sequence(:name) { |n| "SECRET_VAR_#{n}" }
    value { "s3cr3t-value" }

    after(:build) do |variable|
      next if variable.environment.present? || variable.project.blank?

      env = variable.project.environments.first
      unless env
        env = create(:environment, organization: variable.project.organization)
        variable.project.environments << env
      end
      variable.environment = env
    end
  end
end
