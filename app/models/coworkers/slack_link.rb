module Coworkers
  # A Slack user tied to a CloseYourIt account in one organization, and the Puck it last talked to (CYRA-1019).
  class SlackLink < ApplicationRecord
    self.table_name = "coworkers_slack_links"
    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :puck, class_name: "Coworkers::Puck", optional: true
    validates :slack_team_id, :slack_user_id, presence: true
  end
end
