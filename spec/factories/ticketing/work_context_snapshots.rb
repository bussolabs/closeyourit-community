# frozen_string_literal: true

FactoryBot.define do
  factory :work_context_snapshot, class: "Ticketing::WorkContextSnapshot" do
    transient do
      organization { FactoryReuse.organization }
    end

    ticket { create(:ticket, organization: organization) }
    organization_id { ticket.project.organization_id }
    actor { nil }
    actor_name { nil }
    payload { { "references" => [], "procedures" => [] } }
    payload_version { Ticketing::Constants::WORK_CONTEXT_PAYLOAD_VERSION }
    digest { Ticketing::WorkContextSnapshot.compute_digest(payload) }
    generated_at { Time.current }
  end
end
