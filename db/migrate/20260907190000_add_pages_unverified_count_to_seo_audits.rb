# frozen_string_literal: true

# CYRA-808 — quante pagine il giro NON è riuscito a leggere.
#
# `pages_count` da solo racconta una bugia per omissione: dieci pagine "viste" di cui otto andate in
# timeout somigliano a un giro pieno, e il numero dei rilievi che non scende sembra un guasto invece
# che l'unica risposta onesta. Il conteggio sta sul giro, non sul sito: è una proprietà di
# quell'esecuzione, e il giro dopo può andare bene.
class AddPagesUnverifiedCountToSeoAudits < ActiveRecord::Migration[8.1]
  def change
    add_column :seo_audits, :pages_unverified_count, :integer, default: 0, null: false,
               comment: "Pagine tentate ma non lette in questo giro: senza, un controllo cieco somiglia a uno riuscito"
  end
end
