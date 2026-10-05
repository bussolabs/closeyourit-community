# frozen_string_literal: true

# Voce del sommario (TOC) di un book KB. Deliberatamente LEGGERA: solo ciò che serve a orientarsi
# nell'indice (titolo, posizione, tipo, progetto) — niente `body`/`tech_spec`, che si leggono con
# `kb show <page>`. `position` è 0-based (0 = cima), coerente con l'input dell'add-page.
class KnowledgeBookPageSerializer < ApplicationSerializer
  attributes :id, :title, :position

  attribute(:kind) { |page| page.kind }
  # Primo progetto VISIBILE al lettore, non il primo in assoluto. Dopo CYRA-174 una pagina sta su N
  # progetti e `page.project` è uno shim che ne restituisce uno qualsiasi: in un book multi-progetto
  # esporrebbe la key di un progetto che chi legge non vede, vanificando lo scoping anti-leak che il
  # controller applica alle RIGHE del TOC. `params` è il metodo dell'istanza Alba (non il 2° arg del
  # blocco) e porta i visible_*_ids, come in KnowledgePageSerializer.
  attribute(:project) { |page| KnowledgePageSerializer.visible_projects(page, params).first&.key }
end
