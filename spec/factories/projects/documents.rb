# frozen_string_literal: true

FactoryBot.define do
  factory :document, class: "Projects::Document" do
    association :project
    sequence(:title) { |n| "Spec sheet #{n}" }
    description { nil }
    tags { [] }

    after(:build) do |document|
      next if document.file.attached?

      document.file.attach(
        io: StringIO.new("%PDF-1.4 fake"),
        filename: "spec.pdf",
        content_type: "application/pdf"
      )
    end
  end
end
