# frozen_string_literal: true

# CYRA-1154 — one check of a delivered proposal against a main change, born pending like the real one.
FactoryBot.define do
  factory :agent_conflict_check, class: "Agents::ConflictCheck" do
    transient { organization { FactoryReuse.organization } }

    delivery_candidate { create(:agent_delivery_candidate, organization:) }
    workflow { delivery_candidate.workflow }
    repository_full_name { delivery_candidate.repository_full_name }
    number { delivery_candidate.number }
    sequence(:main_sha) { |n| format("%040x", n + 1) }
    state { :pending }
    next_check_at { Time.current }
    main_titles { [ "Add the login page" ] }
    main_commits_count { 1 }
  end
end
