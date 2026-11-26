# frozen_string_literal: true

module Github
  # Link between an issue of a hooked repository and its ticket, one to one. `synced_state` keeps the
  # last state seen on both sides: a field that differs from it changed on that side. CYRA-1055
  class Issue < ApplicationRecord
    # The texts that can be cut on the way in: once cut, they never go back to GitHub. CYRA-1055
    TRUNCATABLE = %w[description].freeze

    belongs_to :repository, class_name: "Github::Repository", inverse_of: :issues
    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :github_issue

    validates :number, presence: true, uniqueness: { scope: :repository_id }
    validates :html_url, presence: true
    validates :ticket_id, uniqueness: true

    def remote_state = synced_state.fetch("remote", {})
    def local_state = synced_state.fetch("local", {})

    def truncated?(field) = truncated_fields.include?(field.to_s)
  end
end
