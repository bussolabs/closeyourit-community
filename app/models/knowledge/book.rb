# frozen_string_literal: true

module Knowledge
  # Collezione ordinata di pagine KB di uno o più progetti/gruppi (vista Outline: indice a sinistra,
  # contenuto della pagina attiva a destra). La lettura filtra progetti e pagine allo scope visibile.
  # L'AUTORE gestisce i propri book, gli altrui sono gated
  # (knowledge.edit/delete, stesso RBAC delle pagine). Una pagina sta al più in UN book
  # (FK diretta knowledge_pages.book_id); l'ordine nel TOC vive su knowledge_pages.position.
  class Book < ApplicationRecord
    belongs_to :created_by, class_name: "Accounts::Account"
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :knowledge_books

    has_many :book_projects,
             class_name: "Connections::BookProject",
             foreign_key: :book_id,
             inverse_of: :book,
             dependent: :destroy
    has_many :projects, through: :book_projects, source: :project
    has_many :book_groups,
             class_name: "Connections::BookGroup",
             foreign_key: :book_id,
             inverse_of: :book,
             dependent: :destroy
    has_many :groups, through: :book_groups, source: :group

    # Pagine del book ordinate per il TOC (position, poi title a parità). dependent: :nullify:
    # cancellare il book NON distrugge le pagine — tornano libere (book_id → nil).
    has_many :pages,
             -> { order(:position, :title) },
             class_name: "Knowledge::Page",
             inverse_of: :book,
             dependent: :nullify

    normalizes :title, with: ->(title) { title.strip }
    normalizes :description, with: ->(description) { description.to_s.strip }

    validates :title, presence: true
    validate :has_project_scope

    scope :ordered, -> { order(updated_at: :desc) }

    # Book raggiungibili da un insieme di progetti: quelli con almeno un progetto EFFETTIVO (diretto
    # o via gruppo) tra i project_ids. Fonte condivisa dell'anti-BOLA di lettura per i canali Member e
    # CLI. Accetta una relation (subquery) o un array di id.
    scope :visible_within, ->(project_ids) {
      where(
        "EXISTS (SELECT 1 FROM connections_book_projects bp WHERE bp.book_id = knowledge_books.id AND bp.project_id IN (?)) " \
        "OR EXISTS (SELECT 1 FROM connections_book_groups bg JOIN projects p ON p.group_id = bg.group_id " \
        "WHERE bg.book_id = knowledge_books.id AND p.id IN (?))", project_ids, project_ids
      )
    }

    def authored_by?(account)
      account.present? && created_by_id == account.id
    end

    def effective_projects
      Projects::Project.where(id: direct_and_group_project_ids)
    end

    # Compatibilità interna durante la migrazione dei caller dal vecchio belongs_to.
    def project = projects.first

    def project=(value)
      return if value.blank?

      self.organization ||= value.organization
      projects << value unless projects.include?(value)
    end

    def project_id = project&.id

    private

    def has_project_scope
      errors.add(:project, I18n.t("member.review_fixes.collection_scope_required")) if projects.empty? && groups.empty?
    end

    def direct_and_group_project_ids
      direct = Connections::BookProject.where(book_id: id).select(:project_id)
      group_ids = Connections::BookGroup.where(book_id: id).select(:group_id)
      Projects::Project.where(id: direct).or(Projects::Project.where(group_id: group_ids)).select(:id)
    end
  end
end
