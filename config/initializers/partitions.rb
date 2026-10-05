# frozen_string_literal: true

# CYRA-750 — le fette delle tabelle di telemetria restano FUORI da `db/schema.rb`.
#
# Il dumper di Rails elenca ogni tabella dello schema e le fette, per lui, sono tabelle come le
# altre: le riscriverebbe con `INHERITS (...)`, che è l'ereditarietà vecchia di PostgreSQL e NON
# una fetta. Un database ricostruito da quel dump avrebbe cinque tabelle padre vuote più venti
# tabelle scollegate, e ogni scrittura finirebbe nel posto sbagliato.
#
# Nel dump resta quindi la sola tabella padre, con il suo `PARTITION BY RANGE`, che Rails 8 sa
# scrivere e rileggere. Le fette le rimette Ops::Partitions::Ensure — chiamata dal giro ricorrente,
# dai comandi di preparazione del database (lib/tasks/partitions.rake) e all'avvio delle prove.
Rails.application.config.to_prepare do
  pattern = Ops::Partitions.dumper_ignore_pattern
  ActiveRecord::SchemaDumper.ignore_tables |= [ pattern ]
end
