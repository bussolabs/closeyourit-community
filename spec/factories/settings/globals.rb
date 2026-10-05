# frozen_string_literal: true

FactoryBot.define do
  factory :settings_global, class: "Settings::Global" do
    logs_retention_days { 14 }
    analytics_retention_days { 365 }
    errors_retention_days { 30 }
    performance_retention_days { 30 }
    servers_retention_days { 30 }
    uptime_retention_days { 730 }
  end
end
