# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ops::WorkerLiveness, type: :service do
  # Registra a mano una riga in solid_queue_processes: nei test non gira un supervisor vero, quindi
  # simuliamo il battito di un processo del motore dei job. Default kind "Worker" (il ruolo esecutore).
  def register_process(last_heartbeat_at:, kind: "Worker", name: "worker-1")
    SolidQueue::Process.create!(kind:, name:, pid: 1, last_heartbeat_at:)
  end

  describe ".alive?" do
    it "true quando almeno un Worker batte da poco" do
      register_process(last_heartbeat_at: Time.current)
      expect(described_class.alive?).to be(true)
    end

    it "false quando tutti i battiti sono più vecchi della soglia (worker fermo)" do
      register_process(last_heartbeat_at: described_class::HEARTBEAT_TIMEOUT.ago - 1.minute)
      expect(described_class.alive?).to be(false)
    end

    it "false se battono solo Supervisor/Dispatcher ma nessun Worker (i job non verrebbero eseguiti)" do
      register_process(last_heartbeat_at: Time.current, kind: "Supervisor(fork)", name: "sup")
      register_process(last_heartbeat_at: Time.current, kind: "Dispatcher", name: "disp")
      expect(described_class.alive?).to be(false)
    end

    it "false quando non c'è alcun processo registrato (motore mai partito o già deregistrato)" do
      expect(described_class.alive?).to be(false)
    end
  end

  describe ".last_heartbeat_at" do
    it "ritorna il battito più recente tra i processi ancora vivi" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        register_process(last_heartbeat_at: 2.minutes.ago, name: "a")
        register_process(last_heartbeat_at: 30.seconds.ago, name: "b")
        expect(described_class.last_heartbeat_at).to be_within(1.second).of(30.seconds.ago)
      end
    end

    it "nil quando ogni battito è scaduto" do
      register_process(last_heartbeat_at: described_class::HEARTBEAT_TIMEOUT.ago - 1.minute)
      expect(described_class.last_heartbeat_at).to be_nil
    end
  end
end
