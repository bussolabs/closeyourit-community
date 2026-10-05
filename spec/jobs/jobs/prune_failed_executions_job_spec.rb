# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::PruneFailedExecutionsJob, type: :job do
  def failed_execution(created_at:, class_name: "Uptime::CheckJob")
    job = SolidQueue::Job.create!(queue_name: "uptime", class_name:, priority: 0,
                                  active_job_id: SecureRandom.uuid, arguments: { "arguments" => [] })
    SolidQueue::FailedExecution.create!(job:, created_at:,
                                        error: { "exception_class" => "AppError", "message" => "boom" })
  end

  it "cancella i falliti oltre la soglia, tiene i recenti" do
    travel_to(Time.utc(2026, 7, 29, 12)) do
      old = failed_execution(created_at: 30.days.ago)
      recent = failed_execution(created_at: 1.day.ago)

      described_class.perform_now

      expect(SolidQueue::FailedExecution.exists?(old.id)).to be(false)
      expect(SolidQueue::FailedExecution.exists?(recent.id)).to be(true)
    end
  end

  it "boundary: 1s prima della soglia cancellato, 1s dopo tenuto" do
    travel_to(Time.utc(2026, 7, 29, 12)) do
      just_old = failed_execution(created_at: described_class::RETENTION.ago - 1.second)
      just_new = failed_execution(created_at: described_class::RETENTION.ago + 1.second)

      described_class.perform_now

      expect(SolidQueue::FailedExecution.exists?(just_old.id)).to be(false)
      expect(SolidQueue::FailedExecution.exists?(just_new.id)).to be(true)
    end
  end

  # Il punto della potatura: un fallito non finisce mai, quindi cancellare la sola esecuzione
  # lascerebbe il job padre in `solid_queue_jobs` con `finished_at` nullo — cioè lo stesso sintomo
  # di prima, contato come "job bloccato", con un'altra faccia.
  it "porta via anche il job padre, senza lasciare orfani" do
    travel_to(Time.utc(2026, 7, 29, 12)) do
      old = failed_execution(created_at: 30.days.ago)
      job_id = old.job_id

      described_class.perform_now

      expect(SolidQueue::Job.exists?(job_id)).to be(false)
    end
  end

  it "non tocca i job finiti in attesa della potatura di Solid Queue" do
    travel_to(Time.utc(2026, 7, 29, 12)) do
      finished = SolidQueue::Job.create!(queue_name: "default", class_name: "Realtime::BroadcastRefreshJob",
                                          priority: 0, active_job_id: SecureRandom.uuid,
                                          arguments: { "arguments" => [] },
                                          created_at: 30.days.ago, finished_at: 30.days.ago)

      described_class.perform_now

      expect(SolidQueue::Job.exists?(finished.id)).to be(true)
    end
  end
end
