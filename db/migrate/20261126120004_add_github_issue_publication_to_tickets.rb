# frozen_string_literal: true

class AddGithubIssuePublicationToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_tickets, :github_issue_publication, :jsonb, null: false, default: {},
                comment: "Publication claim and received issue: retries never create a second issue."
  end
end
