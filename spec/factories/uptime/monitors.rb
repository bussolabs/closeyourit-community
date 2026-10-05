# frozen_string_literal: true

FactoryBot.define do
  factory :uptime_monitor, class: "Uptime::Monitor" do
    # progetto persistito + environment DICHIARATO dal progetto (1 monitor per [progetto, env]).
    project { create(:project) }
    environment { create(:environment, organization: project.organization).tap { |e| project.environments << e } }
    sequence(:name) { |n| "Monitor #{n}" }
    url { "https://example.com/up" }
    http_method { "GET" }
    interval_seconds { 60 }
    expected_status { 200 }
    timeout_seconds { 5 }
    active { true }
    current_status { :unknown }

    trait :up do
      current_status { :up }
    end

    trait :down do
      current_status { :down }
    end

    trait :paused do
      active { false }
    end

    # Check non-web (CYRA-151): url non serve, il bersaglio è host(+port).
    trait :tcp do
      check_type { :tcp }
      url { nil }
      host { "db.example.com" }
      port { 5432 }
    end

    trait :dns do
      check_type { :dns }
      url { nil }
      host { "example.com" }
    end

    trait :ping do
      check_type { :ping }
      url { nil }
      host { "example.com" }
    end

    # Un monitor esiste solo su progetti uptime-capable (≥1 piattaforma web/server): garantiamo che
    # il progetto del monitor lo sia, sia col project di default sia con uno passato esplicitamente.
    after(:build) do |monitor|
      project = monitor.project
      if project && !project.platforms.uptime_capable.exists?
        project.project_platforms.create!(
          platform: create(:platform, :uptime_capable, organization: project.organization)
        )
      end
    end
  end
end
