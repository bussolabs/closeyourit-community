# frozen_string_literal: true

FactoryBot.define do
  factory :integration_credential, class: "Integrations::Credential" do
    organization
    # Il default è l'unico servizio collegabile rimasto (CYRA-765): una factory che nasce su un
    # fornitore fuori registro non sarebbe nemmeno valida.
    provider { "pagespeed" }
    api_key { "AIza-chiave-di-prova-#{SecureRandom.hex(8)}" }

    trait :verified do
      verified_at { Time.current }
      verification_error { nil }
    end

    trait :broken do
      verified_at { 1.day.ago }
      verification_error { Integrations::Verify::INVALID_KEY }
    end

    # Resta anche se coincide col default: le prove della velocità dei siti lo scrivono per dire di
    # QUALE servizio parlano, e leggerle senza sarebbe un indovinello.
    trait :pagespeed do
      provider { "pagespeed" }
    end

    trait :proxanything do
      provider { "proxanything" }
    end
  end
end
