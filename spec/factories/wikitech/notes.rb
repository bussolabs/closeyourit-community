# frozen_string_literal: true

FactoryBot.define do
  factory :wikitech_note, class: "Wikitech::Note" do
    organization { create(:organization) }
    sequence(:body) { |n| "Note #{n}: an open-source game engine with a visual editor." }
    source_label { "TikTok @github.signals" }
    sequence(:source_url) { |n| "https://www.tiktok.com/@github.signals/video/#{n}" }
    links { [] }
    checksum { Wikitech::Note.checksum_for(body: body, source_url: source_url) }
  end
end
