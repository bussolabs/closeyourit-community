# frozen_string_literal: true

# Il giro di prova sulla velocità di un sito (CYRA-539): quanto ci mette, secondo Google, la home a
# comparire su un telefono e su un computer.
#
# UNA RIGA PER (sito, strategia, giro), non una riga con due colonne jsonb: PageSpeed Insights
# fallisce per singola richiesta, e telefono e computer devono poter fallire separatamente senza
# portarsi via a vicenda i numeri buoni dell'altro.
#
# Le colonne di schedulazione stanno SEPARATE da quelle del crawl: un 429 di Google non deve
# ritardare la visita alle pagine, che è un'altra cosa e non dipende da nessuno fuori di qui.
class CreateSeoLabRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :seo_lab_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :site, type: :uuid, null: false,
                          foreign_key: { to_table: :seo_sites, on_delete: :cascade }
      t.integer :strategy, null: false,
                comment: "0 mobile, 1 desktop — mobile prima: è quella con cui Google indicizza"
      t.integer :status, default: 0, null: false, comment: "0 running, 1 completed, 2 failed"
      t.string :url, null: false
      t.string :final_url, comment: "La URL canonica dopo i redirect, come la riporta Google"
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :error,
               comment: "no_api_key | quota_exceeded | unauthorized | invalid_url | lighthouse_error | timeout | upstream_error | unreadable"

      # --- laboratorio (Lighthouse) ---
      # I punteggi sono NULLABILI di proposito: Google li manda a null quando non è riuscito a
      # calcolarli, e uno zero al loro posto dipingerebbe di rosso un sito che nessuno ha misurato.
      t.integer :performance_score
      t.integer :accessibility_score
      t.integer :best_practices_score
      t.integer :seo_score
      t.integer :lab_lcp_ms
      t.integer :lab_fcp_ms
      t.integer :lab_tbt_ms, comment: "Total Blocking Time: il proxy di laboratorio dell'INP, che in laboratorio non esiste"
      t.integer :lab_ttfb_ms
      t.integer :lab_speed_index_ms
      t.decimal :lab_cls, precision: 6, scale: 4

      # --- campo (CrUX, p75 su 28 giorni) — arriva DENTRO la stessa risposta ---
      t.boolean :field_origin_fallback, default: false, null: false,
                comment: "true = i numeri sono dell'ORIGINE, non di questa URL: va detto, non fuso in silenzio"
      t.string :field_overall_category, comment: "FAST | AVERAGE | SLOW | NONE, come lo dice Google"
      t.integer :field_lcp_ms
      t.integer :field_inp_ms
      t.integer :field_fcp_ms
      t.integer :field_ttfb_ms
      t.decimal :field_cls, precision: 6, scale: 4
      t.jsonb :field_distributions, default: {}, null: false,
              comment: "Le tre fasce per metrica come le manda Google: è la prova sotto il p75"

      t.string :lighthouse_version
      t.timestamps

      # La domanda della scheda: l'ultimo giro riuscito di questo sito con questa strategia.
      t.index %i[site_id strategy started_at], order: { started_at: :desc }
    end

    # Nessuna colonna con la risposta grezza: il report Lighthouse intero è centinaia di KB per riga,
    # e su questo disco è già successo che i dati diagnostici completi lo riempissero.

    change_table :seo_sites, bulk: true do |t|
      t.datetime :last_lab_run_at
      t.datetime :next_lab_run_at
      t.string :last_lab_error,
               comment: "Motivo dell'ultima misura fallita: la scheda mostra i numeri buoni precedenti dicendo che sono vecchi"
    end

    # La domanda del dispatcher, una volta all'ora: chi è maturo per una nuova misura?
    add_index :seo_sites, %i[enabled next_lab_run_at]
  end
end
