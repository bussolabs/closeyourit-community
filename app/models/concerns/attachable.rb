# frozen_string_literal: true

# Allegati riutilizzabili (ticket e commenti): `has_many_attached :files` + validazione
# di tipo e dimensione dai limiti in App::Constants. Vedi rules/rails/storage.md.
module Attachable
  extend ActiveSupport::Concern

  # Check condiviso (model validation per record nuovi + pre-attach per record persistiti,
  # dove la validazione del model non bloccherebbe l'attach immediato di ActiveStorage).
  def self.allowed?(content_type:, byte_size:)
    App::Constants::ATTACHMENT_CONTENT_TYPES.include?(content_type) &&
      byte_size.to_i <= max_size_for(content_type)
  end

  # Tetto per tipo: i video hanno il proprio, tutto il resto quello generale.
  def self.max_size_for(content_type)
    App::Constants::VIDEO_CONTENT_TYPES.include?(content_type) ? App::Constants::VIDEO_MAX_SIZE : App::Constants::ATTACHMENT_MAX_SIZE
  end

  included do
    has_many_attached :files

    validate :files_within_allowed_limits
  end

  private

  def files_within_allowed_limits
    files.each do |file|
      blob = file.blob
      next if blob.nil?

      errors.add(:files, :too_large) if blob.byte_size.to_i > Attachable.max_size_for(blob.content_type)
      errors.add(:files, :invalid_type) unless App::Constants::ATTACHMENT_CONTENT_TYPES.include?(blob.content_type)
    end
  end
end
