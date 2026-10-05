FactoryBot.define do
  factory :ticket_priority, class: "Types::TicketPriority" do
    association :organization
    sequence(:code) { |n| "priority_#{n}" }
    label { "Priority" }
    color { "gray" }
    position { 0 }
  end
end
