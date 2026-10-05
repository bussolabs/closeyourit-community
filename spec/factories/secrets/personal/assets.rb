# frozen_string_literal: true

FactoryBot.define do
  # File segreti personali: scoped a [account, organization] (flat, niente environment/project).
  # Le versioni REALI si creano via Secrets::Personal::Assets::Upload negli spec (crypto vera); la factory
  # :personal_secret_asset_version qui sotto serve solo ai model spec delle validazioni (envelope fittizio).
  factory :personal_secret_asset, class: "Secrets::Personal::Asset" do
    association :account
    association :organization
    sequence(:name) { |n| "personal-cert-#{n}.pem" }
    asset_type { "pem" }
  end

  factory :personal_secret_asset_version, class: "Secrets::Personal::AssetVersion" do
    association :asset, factory: :personal_secret_asset
    sequence(:number) { |n| n }
    original_filename { "cert.pem" }
    content_type { "application/octet-stream" }
    byte_size { 128 }
    wrapped_key { "d3JhcHBlZA==" }
    key_iv { "aXY=" }
    key_tag { "dGFn" }
    payload_iv { "aXYy" }
    payload_tag { "dGFnMg==" }
    fingerprint { "abc123def456" }
  end

  factory :personal_secret_asset_event, class: "Secrets::Personal::AssetEvent" do
    association :account
    association :organization
    action { "uploaded" }
    metadata { { "name" => "personal-cert.pem" } }
  end
end
