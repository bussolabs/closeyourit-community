# frozen_string_literal: true

# CYRA-750 — quello che un modello deve sapere quando la sua tabella è divisa a fette.
#
# Due conseguenze, entrambe imposte da PostgreSQL e non da una scelta di stile.
#
# 1. LA CHIAVE PRIMARIA DEL DATABASE HA DUE COLONNE. Su una tabella a fette ogni vincolo di unicità
#    deve contenere la colonna di divisione, quindi sul database la chiave è `(id, <tempo>)`. Qui la
#    si riporta a `id`: l'applicazione continua a vedere un identificativo solo, e `find(id)` resta
#    un accesso per indice perché `id` è la colonna guida della chiave composta.
#
# 2. LA SCRITTURA IN BLOCCO PASSA DA UN GEMELLO. `insert_all` confronta la chiave primaria del
#    MODELLO con quella del DATABASE e, quando non combaciano, si rifiuta di scrivere («No unique
#    index found for id»): dopo il punto 1 non combaciano mai. Il gemello dichiara la chiave come sta
#    sul database, così `insert_all` genera un «salta i duplicati» SENZA bersaglio — l'unica forma
#    che rispetta l'indice unico della chiave naturale, che su una tabella a fette vive su OGNI FETTA
#    e non sul padre (il perché sta in Ops::Partitions). Con un bersaglio esplicito quell'indice non
#    verrebbe consultato e una riconsegna, invece di essere scartata, farebbe fallire l'intero lotto.
#
# Il gemello serve SOLO a scrivere in blocco: niente relazioni, niente validazioni, nessuno lo usa
# per leggere.
module PartitionedTable
  extend ActiveSupport::Concern

  included do
    self.primary_key = "id"

    table = table_name
    const_set(:Bulk, Class.new(ApplicationRecord) do
      self.table_name = table
    end)
  end
end
