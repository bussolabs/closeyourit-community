# frozen_string_literal: true

FactoryBot.define do
  factory :wikitech_source, class: "Wikitech::Source" do
    entry { create(:wikitech_entry) }
    note { create(:wikitech_note, organization: entry.organization) }
    quote { "It does not ask for money when you sell your game." }
  end
end
