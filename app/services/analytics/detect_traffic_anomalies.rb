# frozen_string_literal: true

module Analytics
  # CYRA-147 — "crollo o picco di traffico del sito". Giro periodico che, per ogni progetto che raccoglie
  # analytics, confronta le visite dell'ultima finestra (WINDOW) con la media della STESSA fascia oraria
  # nei BASELINE_DAYS giorni precedenti e, se l'anomalia supera la soglia, accoda l'allarme rule-based
  # (analytics_traffic_drop / analytics_traffic_spike) via Alerting::EvaluateJob — subject = il progetto.
  #
  # CYRA-1116 — la baseline segue il ritmo giorno/notte: alle 3 di notte si confronta con le 3 di notte
  # dei giorni prima, non con una media piatta sulle 24h che faceva sembrare ogni notte un crollo. Il
  # giorno della settimana NON è modellato (servirebbero settimane di storia). Un progetto con meno di
  # BASELINE_DAYS giorni di storia ha una media più bassa e quindi avvisa meno: voluto.
  #
  # Sotto MIN_BASELINE visite attese nella fascia NON si dà alcun verdetto: un'ora di solito quasi vuota
  # non permette di distinguere un crollo dal rumore. Sola lettura: rende visibile un'anomalia, non muta
  # nulla.
  #
  # RE-ALERT: i giri NON vengono collassati dall'anti-spam. Il throttle di default della regola (5 minuti)
  # è molto più corto della cadenza oraria del detector, quindi un'anomalia persistente ri-avvisa a ogni
  # giro (~1 all'ora) finché il traffico non rientra. Chi vuole meno rumore alza il throttle della regola.
  # Il collasso dei giri vale per il promemoria giornaliero delle attività (Workload::DueReminderJob), non
  # qui.
  class DetectTrafficAnomalies < ApplicationService
    WINDOW = Analytics::Constants::TRAFFIC_WINDOW
    BASELINE_DAYS = Analytics::Constants::TRAFFIC_BASELINE_DAYS
    DROP_RATIO = Analytics::Constants::TRAFFIC_DROP_RATIO
    SPIKE_RATIO = Analytics::Constants::TRAFFIC_SPIKE_RATIO

    # min_baseline iniettabile (come window in altri detector): i test verificano la LOGICA con soglie
    # piccole senza dover seminare centinaia di pageview.
    def initialize(now: Time.current, min_baseline: Analytics::Constants::TRAFFIC_MIN_BASELINE)
      @now = now
      @min_baseline = min_baseline
    end

    def call
      flagged = 0
      Projects::Project.analytics_collecting.find_each do |project|
        event_type = anomaly_for(project)
        next if event_type.nil?

        enqueue(project, event_type)
        flagged += 1
      end
      Result.ok(flagged)
    end

    private

    # Verdetto per un progetto: :analytics_traffic_drop, :analytics_traffic_spike o nil (normale / troppo
    # poco traffico storico). Corrente [now-1h, now); baseline = media delle stesse fasce
    # [now-1h-Nd, now-Nd) per N in 1..BASELINE_DAYS, così l'ultima ora non inquina la propria baseline.
    def anomaly_for(project)
      current = pageviews_in(project, @now - WINDOW, @now)
      baseline = same_slot_average(project)
      return nil if baseline < @min_baseline

      return :analytics_traffic_drop if current <= baseline * DROP_RATIO
      return :analytics_traffic_spike if current >= baseline * SPIKE_RATIO

      nil
    end

    # Media delle visite nella stessa fascia oraria dei giorni precedenti. I giorni senza storia contano
    # zero: un progetto nuovo ha una media più bassa e resta più facilmente sotto MIN_BASELINE.
    def same_slot_average(project)
      total = (1..BASELINE_DAYS).sum do |days_ago|
        slot_end = @now - days_ago.days
        pageviews_in(project, slot_end - WINDOW, slot_end)
      end
      total / BASELINE_DAYS.to_f
    end

    # Solo i veri pageview (name = "pageview"): i custom event alimentano i goal, non il traffico.
    def pageviews_in(project, from, to)
      Analytics::Pageview.where(project_id: project.id, name: Analytics::Pageview::PAGEVIEW_NAME,
                                occurred_at: from...to).count
    end

    def enqueue(project, event_type)
      Alerting::EvaluateJob.perform_later(
        event_type: event_type.to_s, subject_type: "Projects::Project",
        subject_id: project.id, project_id: project.id
      )
    end
  end
end
