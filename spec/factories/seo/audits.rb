# frozen_string_literal: true

FactoryBot.define do
  factory :seo_audit, class: "Seo::Audit" do
    site { create(:seo_site) }
    status { :running }
    started_at { Time.current }

    trait :completed do
      status { :completed }
      finished_at { Time.current }
      pages_count { 12 }
      issues_open_count { 3 }
    end

    trait :failed do
      status { :failed }
      finished_at { Time.current }
      error { "connessione rifiutata" }
    end
  end
end
