# frozen_string_literal: true

FactoryBot.define do
  factory :seo_lab_run, class: "Seo::LabRun" do
    site { create(:seo_site) }
    strategy { :mobile }
    status { :running }
    url { site.base_url }
    started_at { Time.current }

    trait :completed do
      status { :completed }
      finished_at { Time.current }
      final_url { "#{site.base_url}/" }
      performance_score { 72 }
      accessibility_score { 94 }
      best_practices_score { 100 }
      seo_score { 88 }
      lab_lcp_ms { 2_842 }
      lab_fcp_ms { 1_503 }
      lab_tbt_ms { 310 }
      lab_ttfb_ms { 619 }
      lab_speed_index_ms { 3_910 }
      lab_cls { 0.0421 }
      lighthouse_version { "12.8.2" }
    end

    trait :with_field do
      field_overall_category { "AVERAGE" }
      field_lcp_ms { 3_120 }
      field_inp_ms { 184 }
      field_fcp_ms { 1_640 }
      field_ttfb_ms { 910 }
      field_cls { 0.08 }
    end

    # I numeri sono dell'origine intera, non di questa URL: la pagina deve dirlo.
    trait :origin_fallback do
      field_origin_fallback { true }
    end

    trait :failed do
      status { :failed }
      finished_at { Time.current }
      error { "quota_exceeded" }
    end

    trait :desktop do
      strategy { :desktop }
    end
  end
end
