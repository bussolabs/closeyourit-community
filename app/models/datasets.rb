# frozen_string_literal: true

module Datasets
  # Dominio della sezione AI: dataset etichettati (colonne dinamiche + foto + una colonna result) su
  # cui si genera un prompt ottimizzato per predire il result via LLM. Vive per-progetto: un dataset
  # appartiene a UN Projects::Project e la visibilità = visibilità del progetto (vedi
  # Authorization::VisibleScope#datasets).
  def self.table_name_prefix = "datasets_"
end
