# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_attachment, class: "Knowledge::Attachment" do
    association :page, factory: :knowledge_page
    sequence(:title) { |n| "Allegato #{n}" }
    description { nil }

    after(:build) do |attachment|
      next if attachment.file.attached?

      attachment.file.attach(
        io: StringIO.new("%PDF-1.4 fake"),
        filename: "spec.pdf",
        content_type: "application/pdf"
      )
    end

    # Script di shell: il caso che distingue questi allegati dai documenti di progetto.
    trait :script do
      title { "Script di deploy" }

      after(:build) do |attachment|
        attachment.file.attach(
          io: StringIO.new("#!/bin/bash\nset -euo pipefail\necho ciao\n"),
          filename: "deploy.sh",
          content_type: "application/x-sh"
        )
      end
    end
  end
end
