# frozen_string_literal: true

# Idea per la CLI. `status` = enum name (open/converted/archived); `ticket_id` = backlink dopo
# la conversione (nil finché aperta/archiviata); `author` = nome umano come in TicketSerializer.
class IdeaSerializer < ApplicationSerializer
  attributes :id, :title, :problem, :solution, :monetization, :risks, :stakeholders, :project_id, :status,
             :votes_count, :comments_count, :cases_count,
             :ticket_id, :converted_at, :created_at, :updated_at

  attribute(:author) { |idea| idea.author&.name }

  # CYRA-845 — collegamenti: l'idea di base (se questa è un'evoluzione), le evoluzioni e i parenti
  # alla pari. Solo id/titolo/stato: il resto si legge con `ideas show` sull'altra idea.
  attribute(:parent) { |idea| idea.parent && brief(idea.parent) }
  attribute(:evolutions) { |idea| idea.evolutions.map { |other| brief(other) } }
  attribute(:related_ideas) { |idea| idea.related_ideas.map { |other| brief(other) } }

  private

  def brief(idea)
    { id: idea.id, title: idea.title, status: idea.status }
  end
end
