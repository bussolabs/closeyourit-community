# frozen_string_literal: true

FactoryBot.define do
  factory :project_move, class: "Projects::Move" do
    association :subject, factory: :project
    source_organization { subject.organization }
    association :destination_organization, factory: :organization
    status { :pending }
  end
end
