# frozen_string_literal: true

module Github
  # A CI job of a connected repository, known by its workflow and its own name (CYRA-1164): two workflows
  # may both have a job called "test". It groups the finished runs GitHub reports and holds the ticket
  # opened from the CI health tab, so a second click reuses it.
  class CiJob < ApplicationRecord
    NAME_LIMIT = 255

    belongs_to :repository, class_name: "Github::Repository", inverse_of: :ci_jobs
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true
    # The foreign key cascades: a repository unlinked from its project takes its runs with it.
    has_many :runs, class_name: "Github::CiJobRun", inverse_of: :ci_job

    normalizes :workflow_name, with: ->(value) { value.to_s.strip.truncate(NAME_LIMIT) }
    normalizes :job_name, with: ->(value) { value.to_s.strip.truncate(NAME_LIMIT) }

    validates :job_name, presence: true

    delegate :project, to: :repository

    # The name the page and the ticket show: "workflow / job".
    def name = workflow_name.present? ? "#{workflow_name} / #{job_name}" : job_name

    # A ticket opened from this job and not closed yet: clicking again leads there instead.
    def open_ticket
      ticket if ticket && ticket.closed_at.nil?
    end

    # Observability::PromoteToTicket asks this: only an open ticket stops a new one.
    def promoted? = open_ticket.present?
  end
end
