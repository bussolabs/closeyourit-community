# frozen_string_literal: true

# Perché e come un gruppo d'errore è stato risolto (CYRA-192).
#
# Due colonne SEPARATE e non una nota unica: rileggendo a mesi di distanza "era il lock di SQLite" e
# "abbiamo escluso l'eccezione nell'SDK" rispondono a domande diverse, e una nota libera le mescola.
# Restano anche dopo una riapertura per regressione: servono proprio a chi ritrova l'errore.
class AddResolutionNotesToErrorsGroups < ActiveRecord::Migration[8.1]
  def change
    change_table :errors_groups, bulk: true do |t|
      t.text :resolution_cause, comment: "Cosa provocava l'errore (compilato alla risoluzione)"
      t.text :resolution_fix, comment: "Cosa è stato fatto per risolverlo"
    end
  end
end
