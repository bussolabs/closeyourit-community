# frozen_string_literal: true

# CYRA-607 — «la versione compare in elenco» non vuol dire «qualcuno l'ha vista in piedi».
#
# L'elenco delle versioni si riempie da due parti. La prima e' il rilascio. La seconda sono le
# segnalazioni di errore che il programma manda da se': dentro ognuna c'e' il numero di versione, e
# alla prima che arriva la riga nasce da sola. Basta un errore nei primi secondi del programma nuovo
# perche' la versione risulti «in elenco» senza che nessuno l'abbia mai vista rispondere.
#
# Finora non faceva male: l'elenco serviva a mostrare cosa gira. Diventa un guaio adesso, perche' sta
# per essere usato per dire che un lavoro e' Fatto — e Fatto vorrebbe dire «provato in produzione».
# Letto com'e', Fatto tornerebbe a essere una voce di corridoio.
#
# Nessuna colonna `proof_source`: la fonte del timbro resta una sola, e una colonna che dice «da dove
# viene» inviterebbe ad aggiungerne altre.
class AddProvedAtToProjectsReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :projects_releases, :proved_at, :datetime
  end
end
