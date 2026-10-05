# frozen_string_literal: true

FactoryBot.define do
  factory :vulnerability_manifest, class: "Vulnerabilities::Manifest" do
    project { create(:project) }
    path { "Gemfile.lock" }
    ecosystem { Vulnerabilities::Ecosystem::RUBYGEMS }
    blob_sha { SecureRandom.hex(20) }
    content_digest { SecureRandom.hex(32) }
    scanned_at { Time.current }

    trait :npm do
      path { "package-lock.json" }
      ecosystem { Vulnerabilities::Ecosystem::NPM }
    end

    trait :pub do
      path { "pubspec.lock" }
      ecosystem { Vulnerabilities::Ecosystem::PUB }
    end

    trait :failing do
      parse_error { "unexpected_token" }
      content_digest { nil }
    end

    # Mai letto: è lo stato in cui nasce un manifest appena scoperto nel tree.
    trait :unread do
      content_digest { nil }
      scanned_at { nil }
    end
  end
end
