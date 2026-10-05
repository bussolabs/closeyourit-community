# frozen_string_literal: true

module Ticketing
  # La risposta a una domanda di un ticket (CYRA-779).
  #
  # Nessuna validazione anti-comando, al contrario della domanda: chi risponde nomina legittimamente
  # un file, un indirizzo o un comando — è spesso il contenuto stesso della risposta. La regola sulla
  # domanda esiste perché una richiesta rivolta a una persona non deve sembrare un'istruzione da
  # eseguire, e su una risposta quella ragione non c'è.
  class Answer < ApplicationRecord
    include Attachable
    include LengthBudget

    belongs_to :question,
               class_name: "Ticketing::Question",
               inverse_of: :answers
    belongs_to :author, class_name: "Accounts::Account"

    enum :origin, { human: 0, agent: 1 }, prefix: true

    normalizes :body,
               with: ->(value) { Text::ItalianOrthography.correct(LengthBudget.normalize_newlines(value)).strip }

    validates :body, presence: true
    length_budget :body, maximum: Ticketing::Constants::ANSWER_MAX_CHARS
    validate :author_belongs_to_organization

    private

    # Stesso isolamento tenant della domanda, raggiunto per la sua strada.
    def author_belongs_to_organization
      org_id = question&.ticket&.project&.organization_id
      return if org_id.blank? || author.blank?
      return if Connections::Membership.exists?(account_id: author.id, organization_id: org_id)

      errors.add(:author, :not_member)
    end
  end
end
