# frozen_string_literal: true

FactoryBot.define do
  factory :error_event, class: "Errors::Event" do
    group { association(:error_group) }
    project { group.project }   # invariante: l'evento eredita il progetto del gruppo
    sequence(:event_id) { |n| n.to_s.rjust(32, "0") }
    occurred_at { Time.current }
    level { :error }
    environment { "production" }
    payload { { "event_id" => event_id, "level" => "error" } }
  end
end
