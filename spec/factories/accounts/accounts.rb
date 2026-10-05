FactoryBot.define do
  factory :account, class: "Accounts::Account" do
    sequence(:email) { |n| "account#{n}@example.com" }
    # handle esplicito e unico: senza, ogni create scatena l'exists? di ensure_handle e il setup che
    # crea N account genera N query a fingerprint identica (prosopite N+1). I test che verificano la
    # generazione automatica passano handle: nil per riattivare ensure_handle.
    sequence(:handle) { |n| "acct#{n}" }
    name { Faker::Name.name }
    password { "Secret123!" }
    god { false }

    # Account di servizio (non-umano, CLI-only). Nella realtà lo conia Accounts::Service::Create con
    # email sintetica + password random; il trait basta ai test che non passano per il service.
    trait :service do
      kind { :service }
      email { "service+#{SecureRandom.hex(8)}@org.cyi.local" }
      handle { "svc_#{SecureRandom.hex(8)}" }
    end

    # 2FA TOTP attivo (CYRA-170). Il seme è FISSO e noto così l'helper di test genera un codice TOTP
    # valido (spec/support/two_factor.rb#current_totp). otp_secret è encrypts: il trait imposta il
    # plaintext, AR lo cifra. Nessun recovery code (il login TOTP non ne ha bisogno).
    trait :with_otp do
      otp_secret { "JBSWY3DPEHPK3PXP" }
      otp_enabled_at { Time.current }
    end
  end
end
