module Coworkers
  # A site a Puck may open, with the login it types for the person (CYRA-1015). Username and password
  # are encrypted; the worker fills them into the page and the model only ever sees placeholders.
  class Site < ApplicationRecord
    self.table_name = "coworkers_sites"
    DOMAIN = /\A(?=.{1,253}\z)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

    belongs_to :puck, class_name: "Coworkers::Puck"
    encrypts :username
    encrypts :password

    before_validation { self.domain = domain.to_s.strip.downcase.delete_prefix("https://").delete_prefix("www.").split("/").first }
    validates :domain, format: { with: DOMAIN }, uniqueness: { scope: :puck_id }
    validate :public_domain

    def placeholders = { "{{#{domain}:username}}" => username.to_s, "{{#{domain}:password}}" => password.to_s }

    private

    def public_domain
      errors.add(:domain, :invalid) if domain.present? && NetworkGuard.private_target?(domain)
    end
  end
end
