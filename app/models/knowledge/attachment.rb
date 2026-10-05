# frozen_string_literal: true

module Knowledge
  # File allegato a UNA pagina della knowledge base: un record = un file, come Projects::Document.
  # `title` è il nome mostrato/rinominabile, separato da `file.blob.filename` (nome originale).
  # Lettura = visibilità della pagina; gestione = chi può modificarla (autore o knowledge.edit).
  #
  # A differenza dei documenti di progetto qui sono ammessi anche gli SCRIPT: una pagina KB descrive
  # una procedura, e lo script che la esegue è parte della documentazione. Restano byte inerti di
  # solo storage — vedi Knowledge::Constants::SCRIPT_CONTENT_TYPES e
  # config/initializers/active_storage.rb per le barriere che ne impediscono l'esecuzione.
  class Attachment < ApplicationRecord
    self.table_name = "knowledge_attachments"

    belongs_to :page,
               class_name: "Knowledge::Page",
               inverse_of: :attachments
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_one_attached :file
    # Nome consegnato al client (send_data della CLI, URL firmata del web): il residuo che
    # ActiveStorage non sanitizza vive in un posto solo, condiviso con Projects::Document.
    include SafeFilename

    # Check condiviso (model validation + pre-attach nel service Upload), come Projects::Document.
    def self.allowed_file?(content_type:, byte_size:)
      Knowledge::Constants::ATTACHMENT_CONTENT_TYPES.include?(content_type) &&
        byte_size.to_i <= Knowledge::Constants::ATTACHMENT_MAX_SIZE
    end

    normalizes :title, with: ->(title) { title.strip }
    normalizes :description, with: ->(description) { description.strip.presence }

    validates :title, presence: true
    validate :file_present
    validate :file_within_allowed_limits

    scope :ordered, -> { order(:position, :created_at, :id) }

    private

    # Il fallback storico di un allegato KB: il concern userebbe "file", qui il record È un allegato.
    def safe_filename_fallback = "allegato"

    def file_present
      errors.add(:file, :blank) unless file.attached?
    end

    def file_within_allowed_limits
      return unless file.attached?

      blob = file.blob
      return if blob.nil?

      errors.add(:file, :too_large) if blob.byte_size.to_i > Knowledge::Constants::ATTACHMENT_MAX_SIZE
      unless Knowledge::Constants::ATTACHMENT_CONTENT_TYPES.include?(blob.content_type)
        errors.add(:file, :invalid_type)
      end
    end
  end
end
