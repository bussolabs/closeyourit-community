# frozen_string_literal: true

module Website
  class AccessRequest < ApplicationRecord
    self.table_name = "website_access_requests"
    normalizes :name, :team, :context, with: ->(value) { value.to_s.strip }
    normalizes :email, with: ->(value) { value.to_s.strip.downcase }
    validates :name, :team, :context, presence: true
    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :locale, inclusion: { in: Website::BaseController::LOCALES }
    validates :status, inclusion: { in: %w[pending contacted accepted declined] }
  end
end
