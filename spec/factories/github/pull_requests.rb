# frozen_string_literal: true

FactoryBot.define do
  factory :github_pull_request, class: "Github::PullRequest" do
    association :repository, factory: :github_repository
    sequence(:number) { |n| n }
    title { "DRRA-1 Fix login" }
    state { :open }
    head_ref { "DRRA-1-fix" }
    base_ref { "main" }
    sequence(:html_url) { |n| "https://github.com/bussolabs/app/pull/#{n}" }
    author_login { "alice" }
  end
end
