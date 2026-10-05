# frozen_string_literal: true

FactoryBot.define do
  factory :vulnerability_advisory, class: "Vulnerabilities::Advisory" do
    sequence(:osv_id) { |n| "GHSA-test-#{n}" }
    aliases { [ "CVE-2024-0000" ] }
    summary { "Possibile XSS in Action Controller" }
    details { "Descrizione estesa dell'advisory." }
    severity { :moderate }
    cvss { "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N" }
    cwe_ids { [ "CWE-79" ] }
    published_at { 30.days.ago }
    modified_at { 2.days.ago }
    refreshed_at { Time.current }

    trait :critical do
      severity { :critical }
    end

    trait :high do
      severity { :high }
    end

    trait :low do
      severity { :low }
    end

    # OSV non classifica sempre: è il caso che NON deve mai aprire un ticket da solo.
    trait :unknown_severity do
      severity { :unknown }
      cvss { nil }
    end

    trait :without_cve do
      aliases { [] }
    end
  end
end
