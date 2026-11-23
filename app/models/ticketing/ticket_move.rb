# frozen_string_literal: true

module Ticketing
  # CYRA-1352 — one move of a ticket to another project: the code it had there keeps leading to it.
  class TicketMove < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :moves
    belongs_to :from_project, class_name: "Projects::Project"
    belongs_to :to_project, class_name: "Projects::Project"
    belongs_to :actor, class_name: "Accounts::Account", optional: true

    validates :from_number, uniqueness: { scope: :from_project_id }

    def from_code = "#{from_project.key}-#{from_number}"
  end
end
