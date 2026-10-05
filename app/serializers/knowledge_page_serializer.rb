# frozen_string_literal: true

# Pagina KB per la CLI. Corpo COMPLETO (markdown sorgente) + sezione tecnica (tech_spec): la CLI è
# canale d'analisi/generazione e deve vedere/scrivere tutto ciò che vede la show web. tech_spec è
# nil se assente. Autore per nome.
#
# Anti-leak: una pagina è visibile con UN solo progetto/gruppo in comune, ma è collegata a N. Se il
# chiamante passa `visible_project_ids`/`visible_group_ids` (Set), progetti e gruppi enumerati sono
# filtrati a quelli visibili — così non trapelano nomi/chiavi di scope che l'utente non vede. Senza
# params (altri contesti) mostra tutto, com'era.
class KnowledgePageSerializer < ApplicationSerializer
  attributes :id, :title, :body, :tech_spec, :publication_key, :created_at, :updated_at

  attribute(:kind) { |page| page.kind }
  # Revisione (CYRA-298): stato della proposta, motivazione di chi l'ha scritta, e il percorso del
  # documento versionato quando la pagina è già stata consolidata nel repo (nil se manca ancora).
  attribute(:status) { |page| page.status }
  attribute(:review_note) { |page| page.review_note }
  attribute(:consolidated_at) { |page| page.consolidated_at }
  attribute(:source_path) { |page| page.source_path }
  # Retrocompat: primo progetto VISIBILE (shim). Preferire `projects` per l'elenco completo N:N.
  # `params` è il metodo dell'istanza Alba (non il 2° arg del blocco): porta i visible_*_ids.
  attribute(:project) { |page| KnowledgePageSerializer.visible_projects(page, params).first&.key }
  attribute(:project_name) { |page| KnowledgePageSerializer.visible_projects(page, params).first&.name }
  attribute(:projects) { |page| KnowledgePageSerializer.visible_projects(page, params).map { |project| { key: project.key, name: project.name } } }
  attribute(:groups) { |page| KnowledgePageSerializer.visible_groups(page, params).map(&:name) }
  attribute(:tags) { |page| page.tags }
  attribute(:author) { |page| page.created_by&.name }
  # CYRA-419: chi ha scritto il testo, separato dall'account il cui accesso è stato usato (`author`).
  # nil = origine non registrata, che non vuol dire «scritta da una persona».
  attribute(:author_kind) { |page| page.author_kind }
  attribute(:author_origin) { |page| page.author_origin }
  # CYRA-768: quando la pagina va riletta (nil = non scade, è il caso delle note) e se il termine è
  # già passato. `needs_review` è derivato e viaggia lo stesso: chi legge dal terminale non deve
  # rifare il confronto con l'ora del server per sapere di cosa può fidarsi.
  attribute(:review_after) { |page| page.review_after }
  attribute(:needs_review) { |page| page.needs_review? }
  # CYRA-764: il verdetto del revisore automatico sul testo live (nil = mai giudicata).
  attribute(:ai_review_format) { |page| page.ai_review_format }
  attribute(:ai_review_verdict) { |page| page.ai_review_verdict }
  attribute(:ai_review_violations) { |page| page.ai_review_violations }
  attribute(:ai_reviewed_at) { |page| page.ai_reviewed_at }

  def self.visible_projects(page, params)
    ids = params && params[:visible_project_ids]
    ids ? page.projects.select { |project| ids.include?(project.id) } : page.projects
  end

  def self.visible_groups(page, params)
    ids = params && params[:visible_group_ids]
    ids ? page.groups.select { |group| ids.include?(group.id) } : page.groups
  end
end
