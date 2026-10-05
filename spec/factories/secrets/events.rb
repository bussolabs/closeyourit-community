# frozen_string_literal: true

FactoryBot.define do
  factory :secret_event, class: "Secrets::Event" do
    project { create(:project) }
    organization { project&.organization }
    action { "read" }
    metadata { {} }
  end
end
