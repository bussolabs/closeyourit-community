# frozen_string_literal: true

FactoryBot.define do
  # Richiesta di approvazione a due (CYRA-138, Fase 4 pezzo C1a). Default action: set (con valore);
  # trait :remove per una richiesta di cancellazione (niente valore).
  factory :secret_change_request, class: "Secrets::ChangeRequest" do
    project { create(:project) }
    organization { project&.organization }
    environment do
      project.environments.first || create(:environment, organization:).tap { |env| project.environments << env }
    end
    requested_by { create(:account) }
    sequence(:name) { |n| "CHANGE_REQUEST_VAR_#{n}" }
    action { "set" }
    value { "requested-value" }

    trait(:remove) do
      action { "remove" }
      value { nil }
    end
  end
end
