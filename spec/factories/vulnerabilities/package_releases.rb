# frozen_string_literal: true

FactoryBot.define do
  factory :vulnerability_package_release, class: "Vulnerabilities::PackageRelease" do
    ecosystem { "RubyGems" }
    sequence(:name) { |n| "gem-#{n}" }
    version { "1.0.0" }
    released_at { 1.day.ago }
  end
end
