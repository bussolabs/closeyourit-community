# frozen_string_literal: true

module Clusters
  # Single place that queues a cluster alert. A workload in a namespace linked to a project goes
  # through the project branch of Alerting::Evaluate, so the project followers get it (CYAG-22).
  module Alerts
    def self.notify(event_type, subject:, cluster:, namespace: nil)
      Alerting::EvaluateJob.perform_later(
        event_type: event_type.to_s, subject_type: subject.class.name, subject_id: subject.id,
        project_id: namespace&.project_id, environment_id: namespace&.environment_id,
        organization_id: cluster.organization_id
      )
    end
  end
end
