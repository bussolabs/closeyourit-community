# frozen_string_literal: true

FactoryBot.define do
  factory :dashboards_feed, class: "Dashboards::Feed" do
    project { create(:project) }
    url { "https://service.example" }
    token { "od_#{SecureRandom.alphanumeric(40)}" }
    enabled { true }
  end
end
