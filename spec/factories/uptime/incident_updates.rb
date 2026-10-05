# frozen_string_literal: true

FactoryBot.define do
  factory :uptime_incident_update, class: "Uptime::IncidentUpdate" do
    association :incident, factory: :uptime_incident
    phase { :investigating }
    body { "Stiamo investigando la causa del problema." }
  end
end
