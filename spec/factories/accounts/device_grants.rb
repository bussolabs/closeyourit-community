FactoryBot.define do
  factory :device_grant, class: "Accounts::DeviceGrant" do
    sequence(:device_code_digest) { |n| Digest::SHA256.hexdigest("device-#{n}") }
    sequence(:user_code) { |n| "WDJB-#{n.to_s.rjust(4, '0')}" }
    client_name { "closeyourit-cli/1.0 (darwin arm64)" }
    status { :pending }
    interval { 5 }
    expires_at { 15.minutes.from_now }

    # Approvata: l'umano ha scelto l'org → account/organization valorizzati + membership garantita.
    trait :approved do
      status { :approved }
      approved_at { Time.current }
      account { create(:account) }
      organization { create(:organization) }

      after(:build) do |grant|
        next if grant.account.blank? || grant.organization.blank?

        unless Connections::Membership.exists?(account_id: grant.account.id,
                                               organization_id: grant.organization.id)
          create(:membership, account: grant.account, organization: grant.organization)
        end
      end
    end

    trait :denied do
      status { :denied }
    end

    trait :expired do
      status { :expired }
      expires_at { 1.minute.ago }
    end
  end
end
