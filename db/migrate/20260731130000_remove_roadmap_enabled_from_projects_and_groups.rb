# frozen_string_literal: true

# CYRA-223: la roadmap smette di essere una capability da accendere. Milestone, board roadmap e
# tipi di ticket non-bug sono disponibili su ogni progetto, quindi il flag non governa più nulla.
#
# Migrazione separata da quella di parent_id: se la gerarchia epic va rifatta, questa resta.
class RemoveRoadmapEnabledFromProjectsAndGroups < ActiveRecord::Migration[8.1]
  def change
    remove_column :projects, :roadmap_enabled, :boolean, default: false, null: false
    remove_column :projects_groups, :roadmap_enabled, :boolean, default: false, null: false
  end
end
