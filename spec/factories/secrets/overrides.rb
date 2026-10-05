# frozen_string_literal: true

FactoryBot.define do
  # L'override richiede un environment DICHIARATO dal progetto (come secret_variable) e un destinatario
  # che sia membro dell'organizzazione del progetto: entrambi garantiti qui, così un test che non si
  # occupa del tenant non deve montarlo a mano.
  factory :secret_override, class: "Secrets::Override" do
    project { create(:project) }
    organization { project&.organization }
    account do
      create(:account).tap { |a| create(:membership, account: a, organization: project.organization, role: :member) }
    end
    sequence(:name) { |n| "OVERRIDE_VAR_#{n}" }
    value { "override-value" }

    after(:build) do |override|
      next if override.environment.present? || override.project.blank?

      env = override.project.environments.first
      unless env
        env = create(:environment, organization: override.project.organization)
        override.project.environments << env
      end
      override.environment = env
    end
  end
end
