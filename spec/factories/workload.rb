# frozen_string_literal: true

FactoryBot.define do
  factory :workload_action, class: "Workload::Action" do
    transient do
      organization { create(:organization) }
    end

    team { create(:team, organization: organization) }
    created_by { create(:account) }
    sequence(:title) { |n| "Action #{n}" }
    status { :planned }

    trait :done do
      status { :done }
      completed_at { Time.current }
    end

    trait :with_ticket do
      ticket { create(:ticket, organization: organization, project: create(:project, organization: organization)) }
    end

    trait :with_participants do
      transient do
        participants_count { 2 }
      end

      after(:create) do |action, evaluator|
        evaluator.participants_count.times do
          create(:connections_workload_participant, action: action)
        end
      end
    end
  end

  factory :connections_workload_participant, class: "Connections::WorkloadParticipant" do
    association :action, factory: :workload_action
    account

    # Il partecipante deve essere membro del team della action (validazione del model): garantiamo
    # la Connections::TeamMembership (che a sua volta crea la Connections::Membership org).
    after(:build) do |participant|
      next if participant.action.blank? || participant.account.blank?

      participant.account.save! if participant.account.new_record?
      team = participant.action.team
      unless Connections::TeamMembership.exists?(account_id: participant.account.id, team_id: team.id)
        create(:team_membership, team: team, account: participant.account)
      end
    end
  end
end
