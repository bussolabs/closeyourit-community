FactoryBot.define do
  factory :ticket_status, class: "Types::TicketStatus" do
    association :organization
    sequence(:code) { |n| "status_#{n}" }
    label { "Status" }
    color { "amber" }
    position { 0 }

    # Semantica review (mirror dei default di Types::InstallDefaults): il gate è lo status
    # "in review" (category in_progress + review_gate: true), i target delle decisioni sono
    # il primo in_progress non-gate (reject) e il primo done (approve).
    trait :in_review do
      label { "In Review" }
      category { :in_progress }
      review_gate { true }
    end

    trait :in_progress do
      label { "In Progress" }
      category { :in_progress }
    end

    trait :done do
      label { "Resolved" }
      category { :done }
    end
  end
end
