# frozen_string_literal: true

# Riga del pacchetto di contesto di un progetto (Knowledge::ProjectContext::Row).
#
# Deliberatamente MINIMA: quanto basta a decidere se una pagina serve — titolo, tipo, tag e una
# riga di riassunto — e nient'altro. Niente `body` né `tech_spec`: dodici corpi interi allegati a
# ogni sessione di lavoro sono esattamente il costo che questo elenco esiste per evitare. Chi vuole
# il contenuto segue l'id con `kb show`.
#
# `updated_at` c'è perché l'elenco è ordinato per freschezza: senza, chi legge non può sapere se
# sta guardando la fotografia di ieri o quella di un anno fa.
class KnowledgeContextPageSerializer < ApplicationSerializer
  attribute(:id) { |row| row.page.id }
  attribute(:title) { |row| row.page.title }
  attribute(:kind) { |row| row.page.kind }
  attribute(:tags) { |row| row.page.tags }
  attribute(:summary) { |row| row.summary }
  attribute(:updated_at) { |row| row.page.updated_at }
end
