# frozen_string_literal: true

FactoryBot.define do
  factory :server_action, class: "Servers::Action" do
    host factory: :server_host
    organization { host.organization }
    kind { "apply_security_updates" }
    status { :queued }
    sequence(:idempotency_key) { |n| "action-#{n}" }
    expires_at { 1.hour.from_now }
  end
end
