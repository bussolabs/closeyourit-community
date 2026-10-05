# frozen_string_literal: true

module Alerting
  # Valutazione asincrona delle regole su coda dedicata :alerts (l'ingest non viene mai rallentato).
  # Enqueued dai trigger SOLO dopo il commit. Difensivo: argomenti per un subject sparito → no-op.
  class EvaluateJob < ApplicationJob
    queue_as :alerts

    def perform(event_type:, subject_type:, subject_id:, project_id:,
                environment: nil, environment_id: nil, level: nil, duration_ms: nil,
                organization_id: nil, value: nil, handled: nil, actor_id: nil)
      Alerting::Evaluate.call(
        event_type: event_type, subject_type: subject_type, subject_id: subject_id,
        project_id: project_id, environment: environment, environment_id: environment_id, level: level,
        duration_ms: duration_ms, organization_id: organization_id, value: value, handled: handled,
        actor_id: actor_id
      )
    end
  end
end
