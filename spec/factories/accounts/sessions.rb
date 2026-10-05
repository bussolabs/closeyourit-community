FactoryBot.define do
  factory :session, class: "Accounts::Session" do
    account
    ip_address { "127.0.0.1" }
    user_agent { "RSpec" }
    # Sessione VIVA di default (CYRA-170): non scaduta, attività appena registrata. Chi testa la
    # scadenza/idle passa expires_at/last_active_at espliciti (trait :expired / :idle).
    last_active_at { Time.current }
    expires_at { Accounts::Constants::SESSION_ABSOLUTE_TTL.from_now }

    trait :expired do
      expires_at { 1.hour.ago }
    end

    trait :idle do
      last_active_at { (Accounts::Constants::SESSION_IDLE_TIMEOUT + 1.hour).ago }
    end
  end
end
