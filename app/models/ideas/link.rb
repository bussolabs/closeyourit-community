# frozen_string_literal: true

module Ideas
  # Collegamento fra due idee dello stesso progetto (CYRA-845).
  #
  # `evolution`: la source EVOLVE la target (source = figlia, target = idea di base). Un solo
  # livello, come gli epic dei ticket: una figlia non ha figlie, e una base non è a sua volta
  # figlia. `related`: parenti alla pari («stesso motore, votarle insieme»): una sola riga per
  # coppia, in qualunque verso, letta da entrambi i lati.
  class Link < ApplicationRecord
    belongs_to :source, class_name: "Ideas::Idea", inverse_of: :outgoing_links
    belongs_to :target, class_name: "Ideas::Idea", inverse_of: :incoming_links

    enum :kind, { evolution: 0, related: 1 }, prefix: true

    validates :kind, presence: true
    validate :distinct_ideas
    validate :same_project
    validate :single_relationship_per_pair
    validate :one_level_evolution, if: :kind_evolution?

    # Tutte le righe che legano `a` e `b`, in qualunque verso.
    scope :between, lambda { |a, b|
      where(source_id: a, target_id: b).or(where(source_id: b, target_id: a))
    }

    private

    def distinct_ideas
      errors.add(:target, :same_idea) if source_id.present? && source_id == target_id
    end

    # Tenancy: le idee stanno nell'org via progetto; un link fra progetti diversi sarebbe un
    # leak (la pagina di un'idea mostrerebbe titoli di un progetto non visibile).
    def same_project
      return if source.nil? || target.nil?

      errors.add(:target, :other_project) if source.project_id != target.project_id
    end

    def single_relationship_per_pair
      return if source_id.blank? || target_id.blank?

      scope = Link.between(source_id, target_id)
      scope = scope.where.not(id: id) if persisted?
      errors.add(:target, :already_linked) if scope.exists?
    end

    # Un solo livello: la base non può essere figlia di qualcun altro, e la figlia non può avere
    # figlie proprie. Le righe già esistenti (non questa) fanno fede.
    def one_level_evolution
      return if source_id.blank? || target_id.blank?

      errors.add(:target, :is_evolution) if Link.kind_evolution.exists?(source_id: target_id)
      errors.add(:source, :has_evolutions) if Link.kind_evolution.exists?(target_id: source_id)
      errors.add(:source, :already_evolves) if Link.kind_evolution.where(source_id:).where.not(id:).exists?
    end
  end
end
