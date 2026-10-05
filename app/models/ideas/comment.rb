module Ideas
  # Commento su un'idea: la discussione del team che l'AI sintetizza alla conversione in
  # ticket. L'autore dev'essere membro dell'org del progetto dell'idea (isolamento tenant).
  # Niente allegati/menzioni in v1 (differenza voluta rispetto a Ticketing::Comment).
  class Comment < ApplicationRecord
    include LengthBudget

    # touch: la discussione è movimento dell'idea, e l'ultimo movimento è ciò che ordina la bacheca
    # (CYRA-360). Senza, un'idea ripresa oggi resterebbe in fondo come una abbandonata da mesi.
    belongs_to :idea,
               class_name: "Ideas::Idea",
               inverse_of: :comments,
               counter_cache: :comments_count,
               touch: true
    belongs_to :author,
               class_name: "Accounts::Account",
               inverse_of: :idea_comments

    normalizes :body, with: ->(value) { LengthBudget.normalize_newlines(value).strip }

    validates :body, presence: true
    # Tetto PROPRIO del dominio idee, non quello dei commenti dei ticket (CYRA-371): qui il commento
    # è il luogo della discussione, non un messaggio breve accanto a un resoconto. Il perché della
    # divergenza sta in Ideas::Constants::COMMENT_MAX_CHARS. Nessuna migrazione: `body` è già text.
    length_budget :body, maximum: Ideas::Constants::COMMENT_MAX_CHARS
    validate :author_belongs_to_organization

    private

    # Isolamento tenant (anti-BOLA): specchio di Ticketing::Comment.
    def author_belongs_to_organization
      org_id = idea&.project&.organization_id
      return if org_id.blank? || author.blank?
      return if Connections::Membership.exists?(account_id: author.id, organization_id: org_id)

      errors.add(:author, :not_member)
    end
  end
end
