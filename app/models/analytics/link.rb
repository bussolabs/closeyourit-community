# frozen_string_literal: true

module Analytics
  # Link pubblico di condivisione/embed della dashboard analytics di un progetto (read-only). Lo slug
  # imprevedibile è la capability d'accesso; la password è opzionale (protezione aggiuntiva); enabled
  # permette la revoca. NON espone mai visitor_hash/IP — la dashboard pubblica mostra solo aggregati.
  class Link < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project", inverse_of: :analytics_links
    # CYRA-697 — chi ha pubblicato. Opzionale: i link nati prima non hanno un autore da inventare.
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    has_secure_password :password, validations: false

    before_validation :ensure_slug, on: :create

    validates :slug, presence: true, uniqueness: true

    scope :active, -> { where(enabled: true) }

    def password_protected? = password_digest.present?

    private

    def ensure_slug
      self.slug ||= SecureRandom.urlsafe_base64(16)
    end
  end
end
