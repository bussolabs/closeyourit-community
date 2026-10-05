FactoryBot.define do
  factory :project_token, class: "Projects::Token" do
    # Il token richiede un environment DICHIARATO da un progetto persistito → il progetto va creato
    # (anche con build(:project_token)): il binding env è dato relazionale, non sta in memoria.
    project { create(:project) }
    name { "Production SDK" }
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("secret-#{n}") }
    sequence(:token_prefix) { |n| "cyi_#{n.to_s.rjust(8, '0')}" }
    sequence(:public_key) { |n| n.to_s.rjust(32, "0") }
    # Un bearer cyi_ è SERVER-ONLY a piena potenza (ingest + read), come Projects::Tokens::Issue.
    # Vedi CYRA-37 / decisions/2026-07-09-cyi-token-server-only.
    scopes { [ "ingest", "read" ] }

    after(:build) do |token|
      next if token.environment.present? || token.project.blank?

      env = token.project.environments.first
      unless env
        env = create(:environment, organization: token.project.organization)
        token.project.environments << env
      end
      token.environment = env
    end

    trait :revoked do
      revoked_at { Time.current }
    end

    # Scadenza già passata (CYRA-716): il token esiste ancora ma non autentica più.
    trait :expired do
      expires_at { 1.day.ago }
      # La validazione vieta di NASCERE scaduto: qui si salta perché la fixture rappresenta un token
      # emesso mesi fa e arrivato a scadenza, non una creazione con data nel passato.
      to_create { |token| token.save(validate: false) }
    end

    # Scadenza dentro la finestra di preavviso.
    trait :expiring_soon do
      expires_at { 3.days.from_now }
    end

    # Token ristretto al solo ingest (es. futuro token browser-safe): non deve leggere la telemetria.
    trait :ingest_only do
      scopes { [ "ingest" ] }
    end

    # Token ristretto alla sola lettura: non deve poter ingestare.
    trait :read_only do
      scopes { [ "read" ] }
    end
  end
end
