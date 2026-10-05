# frozen_string_literal: true

module Projects
  # Documento allegato a UN progetto (spec, contratti, export, zip): un record = un file.
  # `title` è il nome mostrato/rinominabile, separato da `file.blob.filename` (nome originale,
  # che resta ricercabile). Tag liberi normalizzati in `tags` text[] (nessuna entità Tag: il
  # filtro usa l'overlap `&&`). Lettura = visibilità del progetto; gestione = `documents.manage`.
  class Document < ApplicationRecord
    self.table_name = "projects_documents"

    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :documents
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_one_attached :file
    # Nome consegnato al client dal download CLI (send_data): il residuo che ActiveStorage non
    # sanitizza vive in un posto solo, condiviso con Knowledge::Attachment.
    include SafeFilename

    # Activity-log generalizzato (polimorfico): cronologia create/update del documento.
    has_many :activity_events,
             class_name: "Activity::Event",
             as: :subject,
             dependent: :destroy

    # Radice di tenancy del documento = il progetto (delega, non colonna).
    delegate :organization_id, to: :project

    # Check condiviso (model validation + pre-attach nel service Upload), come Attachable.allowed?.
    def self.allowed_file?(content_type:, byte_size:)
      App::Constants::DOCUMENT_CONTENT_TYPES.include?(content_type) &&
        byte_size.to_i <= App::Constants::DOCUMENT_MAX_SIZE
    end

    normalizes :title, with: ->(title) { title.strip }
    normalizes :description, with: ->(description) { description.strip.presence }
    normalizes :tags, with: ->(tags) { Array(tags).map { |tag| tag.to_s.strip.downcase }.reject(&:blank?).uniq }

    validates :title, presence: true
    validate :file_present
    validate :file_within_allowed_limits

    scope :ordered, -> { order(created_at: :desc, id: :desc) }
    # Overlap (OR): il documento matcha se ha ALMENO uno dei tag selezionati — coerente con gli
    # altri filtri multi-select (IN) della UI.
    scope :tagged_any, ->(tags) { where("projects_documents.tags && ARRAY[?]::text[]", Array(tags)) }
    # Title, original filename (a renamed document stays findable) and description. CYRA-883
    scope :search, lambda { |query|
      left_joins(file_attachment: :blob)
        .where("projects_documents.title ILIKE :q OR active_storage_blobs.filename ILIKE :q " \
               "OR projects_documents.description ILIKE :q", q: "%#{sanitize_sql_like(query)}%")
    }

    # Unione ordinata dei tag presenti nello scope: opzioni del filtro tag nella index.
    def self.distinct_tags(scope = all)
      scope.pluck(Arel.sql("DISTINCT unnest(tags)")).sort
    end

    private

    def file_present
      errors.add(:file, :blank) unless file.attached?
    end

    def file_within_allowed_limits
      return unless file.attached?

      blob = file.blob
      return if blob.nil?

      errors.add(:file, :too_large) if blob.byte_size.to_i > App::Constants::DOCUMENT_MAX_SIZE
      errors.add(:file, :invalid_type) unless App::Constants::DOCUMENT_CONTENT_TYPES.include?(blob.content_type)
    end
  end
end
