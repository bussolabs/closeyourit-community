# frozen_string_literal: true

FactoryBot.define do
  factory :wikitech_entry, class: "Wikitech::Entry" do
    organization { create(:organization) }
    sequence(:name) { |n| "Engine #{n}" }
    summary { "An engine to make 2D and 3D games with a visual editor." }
    facts { [ "Free alternative to Unity" ] }
    categories { [ "game dev" ] }
  end
end
