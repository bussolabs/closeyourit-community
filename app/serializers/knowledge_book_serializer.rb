# frozen_string_literal: true

# Book KB per la CLI: metadati della collezione. Progetti, gruppi, sommario (TOC) e conteggio pagine
# NON stanno qui: sono SCOPED alla visibilità del lettore e iniettati dal controller (anti-leak su
# book multi-progetto — key di progetti, nomi di gruppi e titoli di pagine fuori vista non trapelano).
# Autore per nome.
class KnowledgeBookSerializer < ApplicationSerializer
  attributes :id, :title, :description, :created_at, :updated_at

  attribute(:author) { |book| book.created_by&.name }
end
