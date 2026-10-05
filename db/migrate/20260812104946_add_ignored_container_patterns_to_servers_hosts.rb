# frozen_string_literal: true

# CYRA-489 — l'avviso «container caduto» scattava sul lavoro normale delle build: i container di
# compilazione e test nascono e muoiono a ogni lavorazione, e l'unica difesa era spegnere l'intera
# regola, perdendo anche i guasti veri. Qui la macchina dichiara quali nomi NON sono servizi.
class AddIgnoredContainerPatternsToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :ignored_container_patterns, :jsonb, null: false, default: []
  end
end
