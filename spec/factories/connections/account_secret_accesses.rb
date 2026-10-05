# frozen_string_literal: true

FactoryBot.define do
  factory :account_secret_access, class: "Connections::AccountSecretAccess" do
    account
    project
    organization { project.organization }
    environment_codes { [ "production" ] }
  end
end
