# frozen_string_literal: true

# Un sito sotto controllo SEO, sul canale CLI. `last_error` esce sempre: un giro fallito che
# somigliasse a un giro riuscito è la cosa peggiore che questa risposta possa fare.
class SeoSiteSerializer < ApplicationSerializer
  attributes :id, :base_url, :enabled, :max_pages, :follow_sitemap,
             :last_audited_at, :next_audit_at, :last_error

  attribute(:frequency) { |site| site.frequency }
  attribute(:open_issues_count) { |site| site.open_issues_count }

  attribute(:project) do |site|
    { id: site.project_id, key: site.project.key, name: site.project.name }
  end

  attribute(:environment) do |site|
    { id: site.environment_id, code: site.environment.code, label: site.environment.label }
  end

  # --- La scheda di un sito (CYRA-541) ---------------------------------------------------------
  #
  # I blocchi in più escono SOLO quando il chiamante li passa — la lettura di un sito singolo — perché
  # l'elenco non ha motivo di pagarli. E un blocco senza dati non esce affatto: `last_audit: null`
  # diventa un'intestazione vuota a schermo, che si legge come «qui non c'è niente da vedere» invece
  # di «non è ancora successo niente». I conteggi invece ci sono sempre: zero rilievi aperti è una
  # risposta, non un blocco vuoto.
  attribute :issues, if: proc { params[:issue_counts] } do
    params[:issue_counts]
  end

  attribute :pages_count, if: proc { params.key?(:pages_count) } do
    params[:pages_count]
  end

  # Chi ha collegato il servizio di misura può aspettarsi numeri; chi non l'ha collegato no, e va
  # detto (CYRA-546) — altrimenti «nessuna misura» sembra una questione di tempo.
  attribute :lab_configured, if: proc { params.key?(:lab_configured) } do
    params[:lab_configured]
  end

  # Com'è andato l'ultimo giro di visita, compreso il caso in cui è fallito: `error` esce sempre,
  # anche a nulla, per la stessa ragione di `last_error`.
  #
  # `pages_unverified_count` esce accanto a `pages_count` e non al suo posto (CYRA-808): dodici
  # pagine "viste" di cui otto mute somigliano a dodici pagine controllate, e i rilievi che non
  # scendono sembrano un guasto. Le schermate lo dicono, e questa risposta deve dire lo stesso —
  # una verità sola su due canali, altrimenti il canale silenzioso diventa quello di cui fidarsi
  # meno senza che nessuno lo sappia.
  attribute :last_audit, if: proc { params[:last_audit] } do
    audit = params[:last_audit]
    { status: audit.status, started_at: audit.started_at, finished_at: audit.finished_at,
      duration_seconds: audit.duration_seconds, pages_count: audit.pages_count,
      pages_unverified_count: audit.pages_unverified_count,
      issues_open_count: audit.issues_open_count, error: audit.error }
  end

  # Quanto è veloce. Il blocco c'è quando c'è qualcosa da dire: un giro riuscito, oppure il motivo per
  # cui l'ultima misura è fallita — tacere quel motivo sarebbe il degrado silenzioso, cioè far sembrare
  # un guasto una misura che non è ancora arrivata.
  attribute :performance, if: proc { |site| SeoSiteSerializer.performance?(site, params) } do |site|
    { last_run_at: site.last_lab_run_at, last_error: site.last_lab_error }
      .merge(params[:lab_runs].transform_values { |run| SeoSiteSerializer.lab_payload(run) })
  end

  def self.performance?(site, params)
    return false unless params.key?(:lab_runs)

    params[:lab_runs].present? || site.last_lab_error.present?
  end

  # Un giro di laboratorio come lo legge la scheda a schermo: i quattro punteggi col loro verdetto, le
  # misure di laboratorio che li spiegano, e il p75 di campo quando Google ne ha abbastanza.
  #
  # I verdetti arrivano da `Seo::Vitals` e non dal client: le soglie stanno in un posto solo, e una
  # riga di comando che le riapplicasse per conto proprio darebbe un giudizio diverso dalla schermata
  # sullo stesso numero.
  def self.lab_payload(run)
    payload = { measured_at: run.started_at, scores: run.scores,
                score_ratings: run.scores.transform_values { |score| Seo::Vitals.score_rating(score) },
                lab: run.lab_metrics }
    return payload unless run.field?

    payload.merge(field: field_payload(run))
  end

  # Le misure dei visitatori veri. `origin_fallback` non si tace: quando è vero i numeri sono
  # dell'origine intera e non di questa URL, e presentarli come «di questo indirizzo» sarebbe falso.
  def self.field_payload(run)
    metrics = run.field_metrics
    { metrics: metrics,
      ratings: metrics.to_h { |metric, value| [ metric, Seo::Vitals.rating(metric, value) ] },
      origin_fallback: run.field_origin_fallback }
  end
end
