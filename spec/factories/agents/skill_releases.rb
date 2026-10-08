# frozen_string_literal: true

FactoryBot.define do
  factory :skill_release, class: "Agents::SkillRelease" do
    sequence(:version) { |n| "1.#{n}.0" }
    url { "https://github.com/bussolabs/cyi-skills/releases/download/v#{version}/cyi-#{version}.tgz" }
    sha256 { SecureRandom.hex(32) }
    git_sha { SecureRandom.hex(20) }
    published_at { Time.current }
  end

  factory :skill_release_pin, class: "Agents::SkillReleasePin" do
    organization
    skill_release
  end
end
