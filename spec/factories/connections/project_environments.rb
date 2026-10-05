# frozen_string_literal: true

FactoryBot.define do
  factory :project_environment, class: "Connections::ProjectEnvironment" do
    association :project
    environment { association(:environment, organization: project.organization) }

    # Override di capability (nil di default = eredita il default dell'ambiente).
    trait(:override_servers_off) { servers_enabled { false } }
    trait(:override_servers_on) { servers_enabled { true } }
    trait(:override_uptime_off) { uptime_enabled { false } }
    trait(:override_uptime_on) { uptime_enabled { true } }
    trait(:override_secrets_off) { secrets_enabled { false } }
    trait(:override_secrets_on) { secrets_enabled { true } }
    trait(:override_approval_off) { approval_required { false } }
    trait(:override_approval_on) { approval_required { true } }
  end
end
