# frozen_string_literal: true

module Helpdesk
  # One message of a request: what the visitor wrote, later what the team answers (CYRA-940).
  class Message < ApplicationRecord
    include LengthBudget

    attr_readonly :request_id, :direction

    belongs_to :request, class_name: "Helpdesk::Request", inverse_of: :messages
    belongs_to :author, class_name: "Accounts::Account", optional: true

    enum :direction, { inbound: 0, outbound: 1 }, prefix: true, validate: true

    # Plain text only: tags are dropped before saving, the pages escape the rest.
    normalizes :body, with: ->(value) { LengthBudget.normalize_newlines(ActionController::Base.helpers.strip_tags(value.to_s)).strip }

    validates :body, presence: true
    length_budget :body, maximum: Helpdesk::Constants::BODY_MAX_CHARS
  end
end
