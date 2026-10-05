# frozen_string_literal: true

FactoryBot.define do
  factory :server_journal_entry, class: "Servers::Journal::Entry" do
    host factory: :server_host
    organization { host.organization }
    occurred_at { Time.current }
    priority { 3 }
    unit { "backup" }
    message { "Backup job failed: connection refused" }
    sequence(:cursor) { |n| "s=abc;i=#{format('%x', n)};b=boot0001;m=100200300;t=6551abc;x=deadbeef" }
  end
end
