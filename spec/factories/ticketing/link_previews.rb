FactoryBot.define do
  factory :link_preview, class: "Ticketing::LinkPreview" do
    organization { FactoryReuse.organization }
    sequence(:url) { |n| "https://www.figma.com/file/#{n}/Design" }
    status { "ready" }
    title { "Checkout redesign" }
    site_name { "Figma" }
    expires_at { Ticketing::LinkPreview::READY_FOR.from_now }

    trait :with_image do
      after(:create) do |preview|
        preview.image.attach(io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
                             filename: "preview.png", content_type: "image/png", identify: false)
      end
    end
  end
end
