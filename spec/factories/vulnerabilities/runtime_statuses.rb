# frozen_string_literal: true

FactoryBot.define do
  factory :vulnerability_runtime_status, class: "Vulnerabilities::RuntimeStatus" do
    project { create(:project) }
    name { "ruby" }
    version { "3.4.2" }
    cycle { "3.4" }
    eol_on { 2.years.from_now.to_date }
    latest { "3.4.10" }
    state { :supported }
    source_path { "mise.toml" }
    checked_at { Time.current }

    trait :ending_soon do
      eol_on { 30.days.from_now.to_date }
      state { :ending_soon }
    end

    trait :eol do
      version { "3.0.6" }
      cycle { "3.0" }
      eol_on { 1.year.ago.to_date }
      state { :eol }
    end

    # endoflife.date non conosce il prodotto o non dichiara la data: nessun allarme possibile.
    trait :undated do
      eol_on { nil }
      latest { nil }
    end
  end
end
