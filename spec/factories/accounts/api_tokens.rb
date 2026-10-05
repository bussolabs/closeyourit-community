FactoryBot.define do
  factory :api_token, class: "Accounts::ApiToken" do
    # account/organization sempre persistiti (come project_token con il progetto): il vincolo tenant è
    # dato relazionale (membership in DB), non sta in memoria. Evita anche l'autosave a cascata del
    # token via inverse_of quando si testa un token volutamente invalido.
    account { create(:account) }
    organization { create(:organization) }
    name { "MacBook · oclif" }
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("user-secret-#{n}") }
    sequence(:token_prefix) { |n| "cyi_u_#{n.to_s.rjust(8, '0')}" }

    # Integrità tenant: l'account dev'essere membro dell'org (validato sul model) → factory sempre valida.
    after(:build) do |token|
      next if token.account.blank? || token.organization.blank?

      unless Connections::Membership.exists?(account_id: token.account.id,
                                             organization_id: token.organization.id)
        create(:membership, account: token.account, organization: token.organization)
      end
    end

    trait :revoked do
      revoked_at { Time.current }
    end

    # Scadenza già passata (CYRA-717): il token esiste ancora ma non autentica più.
    trait :expired do
      expires_at { 1.hour.ago }
      # La validazione vieta di NASCERE scaduto: qui si salta perché la fixture rappresenta un token
      # emesso mesi fa e arrivato a scadenza, non una creazione con data nel passato.
      to_create { |token| token.save(validate: false) }
    end

    # Scadenza dentro la finestra di preavviso.
    trait :expiring_soon do
      expires_at { 3.days.from_now }
    end
  end
end
