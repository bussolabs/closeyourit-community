# frozen_string_literal: true

module Helpdesk
  # A request written by a visitor of a project's site (CYRA-940). Not a ticket: the team reads it
  # and decides. The visitor has no account, so the email is the only way back to them.
  class Request < ApplicationRecord
    attr_readonly :project_id

    belongs_to :project, class_name: "Projects::Project", inverse_of: :helpdesk_requests
    belongs_to :discarded_by, class_name: "Accounts::Account", optional: true
    # The ticket this request became (converted) or joined (linked). Many requests, one ticket.
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true, inverse_of: :helpdesk_requests
    has_many :messages, -> { order(:created_at) }, class_name: "Helpdesk::Message",
                                                   inverse_of: :request, dependent: :destroy

    encrypts :email

    # Meaning of the first message (CYRA-943): groups the requests that say the same thing.
    has_neighbors :embedding
    scope :current_embedding, -> { where(embedding_version: Ai::Configuration.current.embedding_version) }

    enum :status, { received: 0, discarded: 1, converted: 2, linked: 3, answered: 4 }, prefix: true, validate: true

    validates :summary, presence: true, length: { maximum: Helpdesk::Constants::SUMMARY_MAX_CHARS }
    validates :email, length: { maximum: Helpdesk::Constants::EMAIL_MAX_CHARS },
                      format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
    validates :page_url, length: { maximum: Helpdesk::Constants::PAGE_URL_MAX_CHARS }
    validates :session_id, length: { maximum: Helpdesk::Constants::SESSION_ID_MAX_CHARS }

    def email_erased? = email_erased_at.present?

    # Still to triage: it can become a ticket, join one or be discarded. An answer does not close it.
    def open? = status_received? || status_answered?
  end
end
