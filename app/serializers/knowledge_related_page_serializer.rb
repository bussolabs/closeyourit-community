# frozen_string_literal: true

# Riga "pagina correlata" per la CLI (Knowledge::RelatedPages::Row). Deliberatamente LEGGERA:
# niente `body` né `tech_spec` — cinque pagine intere allegate ad ogni `kb show` renderebbero
# illeggibile l'output. Chi vuole il contenuto segue l'id con `kb show`.
#
# `via` dice PERCHÉ la pagina è qui (link = wikilink scritto da una persona, semantic = vicinanza
# di significato) e `relevance` quanto c'entra con la domanda posta (1.0 = identica; null quando
# non è stata posta una domanda o la pagina non è ancora indicizzata).
class KnowledgeRelatedPageSerializer < ApplicationSerializer
  attribute(:id) { |row| row.page.id }
  attribute(:title) { |row| row.page.title }
  attribute(:kind) { |row| row.page.kind }
  # Anti-leak: primo progetto VISIBILE al chiamante (`params` = metodo istanza Alba, come KnowledgePageSerializer).
  attribute(:project) { |row| KnowledgeRelatedPageSerializer.visible_first(row.page, params)&.key }
  attribute(:via) { |row| row.via.to_s }
  attribute(:relevance) { |row| row.relevance }

  def self.visible_first(page, params)
    ids = params && params[:visible_project_ids]
    (ids ? page.projects.select { |project| ids.include?(project.id) } : page.projects).first
  end
end
