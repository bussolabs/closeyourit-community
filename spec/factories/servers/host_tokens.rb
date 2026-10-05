# frozen_string_literal: true

FactoryBot.define do
  factory :server_host_token, class: "Servers::HostToken" do
    host factory: :server_host
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("host-token-#{n}") }
    sequence(:token_prefix) { |n| "cyi_h_#{n}" }
  end
end
