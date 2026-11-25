# frozen_string_literal: true

module Ticketing
  # What a link written in a ticket description shows as a card: title, short description, site and an
  # image kept in our storage, so the reader's browser never calls the other site (CYRA-1163).
  # One row per organization and address; `expires_at` says when it may be read again.
  class LinkPreview < ApplicationRecord
    READY_FOR = 7.days
    FAILED_FOR = 1.hour
    MAX_URL_LENGTH = 2048

    belongs_to :organization, class_name: "Organizations::Organization"
    has_one_attached :image

    enum :status, { ready: "ready", failed: "failed" }, validate: true

    validates :url, presence: true, length: { maximum: MAX_URL_LENGTH }, uniqueness: { scope: :organization_id }
    validates :expires_at, presence: true

    scope :expired, -> { where(expires_at: ..Time.current) }

    def fresh? = expires_at.future?

    # A card only when the page declared a title: a card with just the site name says less than the link.
    def card? = ready? && title.present?
  end
end
