FactoryBot.define do
  factory :agent_ticket_queue_deferral, class: "Agents::TicketQueueDeferral" do
    transient { organization_record { FactoryReuse.organization } }
    organization { organization_record }
    ticket { create(:ticket, organization:) }
    host { create(:agent_host, organization:) }
    execution_phase { "triage" }
    reason { "temporary_failure" }
    retry_at { 5.minutes.from_now }
    sequence(:selection_digest) { |n| Digest::SHA256.hexdigest("selection-#{n}") }
    candidate_version { Digest::SHA256.hexdigest("candidate") }
    repository_fingerprint { Digest::SHA256.hexdigest("repository") }
  end
end
