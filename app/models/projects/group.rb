module Projects
  # Gruppo (macro-progetto): contenitore di progetti correlati, es. "DriverOne" →
  # driverone-rails/-flutter/-angular. Non ha ticket/key propri. Un account assegnato al gruppo
  # (Connections::GroupMembership) vede TUTTI i suoi progetti, presenti e futuri.
  # Cancellazione: i progetti sopravvivono e diventano "senza gruppo" (dependent: :nullify).
  class Group < ApplicationRecord
    # Il namespace Projects non ha table_name_prefix (Projects::Project → "projects"); fissiamo il
    # nome esplicito, come Accounts::Session. Vedi rules/rails/models.md.
    self.table_name = "projects_groups"

    include Iconable

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :groups
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :projects,
             class_name: "Projects::Project",
             foreign_key: :group_id,
             inverse_of: :group,
             dependent: :nullify

    has_many :group_memberships,
             class_name: "Connections::GroupMembership",
             foreign_key: :group_id,
             inverse_of: :group,
             dependent: :destroy
    has_many :members, through: :group_memberships, source: :account

    has_many :book_groups,
             class_name: "Connections::BookGroup",
             foreign_key: :group_id,
             inverse_of: :group,
             dependent: :destroy
    has_many :knowledge_books, through: :book_groups, source: :book

    # Pagine KB collegate direttamente a questo gruppo (valgono per tutti i suoi progetti).
    has_many :page_groups,
             class_name: "Connections::PageGroup",
             foreign_key: :group_id,
             inverse_of: :group,
             dependent: :destroy
    has_many :knowledge_pages, through: :page_groups, source: :page

    # Guidance (CYRA-74) dichiarata a livello GRUPPO come owner. La legge Guidance::Resolve, non da qui.
    has_many :guidance_references,
             class_name: "Guidance::Reference",
             as: :owner,
             dependent: :destroy
    has_many :guidance_procedures,
             class_name: "Guidance::Procedure",
             as: :owner,
             dependent: :destroy

    # Matrice funzionalità × piattaforme del prodotto (CYRA-256): le categorie sono le sue righe.
    # Cascade col gruppo: la matrice è del gruppo e non è riassegnabile altrove (i progetti invece
    # sopravvivono, dependent: :nullify sopra).
    has_many :feature_categories,
             class_name: "Product::Category",
             foreign_key: :group_id,
             inverse_of: :group,
             dependent: :destroy

    # Team collegati a questo gruppo-di-progetti (scope RBAC: copre tutti i progetti del gruppo).
    has_many :team_accesses,
             class_name: "Connections::TeamGroupAccess",
             foreign_key: :group_id,
             inverse_of: :group,
             dependent: :destroy

    normalizes :name, with: ->(name) { name.strip }

    validates :name, presence: true

    # The group's color is its projects' color (see Projects::Project#take_group_color).
    after_save :repaint_projects, if: -> { saved_change_to_color? && color.present? }

    scope :ordered, -> { order(:name) }

    private

    def repaint_projects
      projects.where.not(color: color).or(projects.where(color: nil)).update_all(color: color)
    end
  end
end
