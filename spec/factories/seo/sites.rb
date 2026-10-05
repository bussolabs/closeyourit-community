# frozen_string_literal: true

FactoryBot.define do
  factory :seo_site, class: "Seo::Site" do
    # progetto persistito + ambiente DICHIARATO dal progetto (1 sito per [progetto, ambiente]),
    # stessa forma della factory :uptime_monitor.
    project { create(:project) }
    environment { create(:environment, organization: project.organization).tap { |e| project.environments << e } }
    base_url { "https://example.com" }
    enabled { true }
    frequency { :daily }
    max_pages { 100 }
    follow_sitemap { true }

    trait :weekly do
      frequency { :weekly }
    end

    trait :disabled do
      enabled { false }
    end

    trait :due do
      next_audit_at { 1.hour.ago }
    end

    trait :audited do
      last_audited_at { 1.hour.ago }
      next_audit_at { 23.hours.from_now }
    end

    # Un sito esiste solo su progetti con una piattaforma web (analytics-capable): la garantiamo sia
    # col project di default sia con uno passato esplicitamente, altrimenti la validazione di
    # ammissione fa fallire ogni create.
    after(:build) do |site|
      project = site.project
      next if project.blank? || project.platforms.analytics_capable.exists?

      project.project_platforms.create!(
        platform: create(:platform, organization: project.organization, supports_analytics: true)
      )
    end
  end
end
