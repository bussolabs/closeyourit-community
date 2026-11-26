# frozen_string_literal: true

FactoryBot.define do
  # A ticket aligned with an issue (CYRA-1055). The synced state is the ticket as it is now and an issue
  # identical to it: nothing is pending on either side until the test changes one.
  factory :github_issue, class: "Github::Issue" do
    repository { create(:github_repository, issue_sync: :all_issues) }
    ticket { create(:ticket, project: repository.project) }
    sequence(:number) { |n| 100 + n }
    html_url { "https://github.com/#{repository.full_name}/issues/#{number}" }
    sequence(:node_id) { |n| "I_node#{n}" }
    author_login { "octocat" }
    github_updated_at { 1.hour.ago }

    after(:build) do |link|
      ticket = link.ticket
      link.synced_state = {
        "remote" => { "title" => ticket.title, "body" => ticket.description.to_s, "closed" => false,
                      "labels" => [], "assignees" => [] },
        "local" => Github::Issues::Snapshot.local(ticket)
      }
    end
  end
end
