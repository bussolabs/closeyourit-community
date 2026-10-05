# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_version, class: "Knowledge::Version" do
    page { create(:knowledge_page) }
    organization { page.project.organization }
    created_by { page.created_by }
    author_name { created_by&.name }
    sequence(:number) { |n| n }
    title { Faker::Lorem.sentence }
    body { Faker::Lorem.paragraph }
    kind { :note }
  end
end
