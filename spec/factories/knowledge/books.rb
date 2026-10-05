# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_book, class: "Knowledge::Book" do
    transient do
      organization { create(:organization) }
    end

    project { create(:project, organization: organization) }
    created_by do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    title { Faker::Lorem.sentence }
    description { Faker::Lorem.paragraph }
  end
end
