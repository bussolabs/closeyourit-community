# frozen_string_literal: true

FactoryBot.define do
  factory :vulnerability_package, class: "Vulnerabilities::Package" do
    manifest { create(:vulnerability_manifest) }
    sequence(:name) { |n| "gem-#{n}" }
    version { "1.0.0" }
    # L'ecosistema segue il manifest che lo contiene: una discrepanza qui sarebbe uno stato che la
    # scansione non produce mai.
    ecosystem { manifest.ecosystem }
    direct { false }

    trait :direct do
      direct { true }
    end
  end
end
