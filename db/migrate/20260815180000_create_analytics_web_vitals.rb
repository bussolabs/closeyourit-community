# frozen_string_literal: true

# Le misure di velocità prese dai visitatori veri (CYRA-538): quanto ci ha messo la pagina a
# comparire, a reagire al tocco, quanto si è spostata mentre caricava.
#
# FORMATO LUNGO — una riga per misura, non una riga per caricamento con cinque colonne. Le metriche
# arrivano in momenti diversi (l'attesa del server subito, i salti della pagina e la risposta al
# tocco solo quando il visitatore se ne va), quindi una riga larga richiederebbe una UPDATE sul
# percorso caldo dell'ingest e darebbe comunque la risposta sbagliata ogni volta che qualcuno chiude
# la scheda prima. Il percentile, poi, si calcola per metrica indipendentemente: una tabella larga
# piena di NULL darebbe la stessa risposta con più codice.
#
# NESSUN visitor_hash, di proposito. Una misura di prestazione non ha bisogno di sapere CHI: non
# salvarlo toglie dal tavolo l'intera superficie di re-identificazione per questo segnale. Prezzo
# dichiarato: non si può dire «quanti visitatori distinti hanno avuto una pagina lenta», e chi
# ricarica venti volte pesa venti volte. Con un percentile e questi volumi è un prezzo giusto.
class CreateAnalyticsWebVitals < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_web_vitals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_id, null: false, comment: "Idempotenza (project_id, event_id), come i pageview"
      t.string :metric, null: false, comment: "lcp | inp | cls | ttfb | fcp — allowlist server-side"
      t.float :value, null: false, comment: "ms per lcp/inp/ttfb/fcp; adimensionale per cls"
      t.string :rating, comment: "good | needs-improvement | poor — RICALCOLATO qui, mai preso dal client"
      t.string :hostname, null: false
      t.string :path, null: false
      t.string :environment
      t.string :device_type, comment: "desktop | mobile | tablet — dallo user-agent, come i pageview"
      t.string :browser
      t.string :os
      t.string :country_code
      t.string :navigation_type,
               comment: "navigate | reload | back-forward | prerender: un back-forward è cache e falserebbe il confronto"
      t.datetime :occurred_at, null: false
      # Solo created_at: una misura è un fatto avvenuto, non si aggiorna mai. Come analytics_pageviews.
      t.datetime :created_at, null: false

      t.index %i[project_id event_id], unique: true
      t.index %i[project_id metric occurred_at], order: { occurred_at: :desc }
      t.index %i[project_id hostname metric occurred_at], order: { occurred_at: :desc },
              name: "index_analytics_web_vitals_site_lookup"
    end
  end
end
