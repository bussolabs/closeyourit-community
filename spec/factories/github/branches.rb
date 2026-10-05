# frozen_string_literal: true

FactoryBot.define do
  factory :github_branch, class: "Github::Branch" do
    association :repository, factory: :github_repository
    sequence(:name) { |n| "DRRA-#{n}-fix" }
    html_url { "https://github.com/bussolabs/app/tree/#{name}" }
  end
end
