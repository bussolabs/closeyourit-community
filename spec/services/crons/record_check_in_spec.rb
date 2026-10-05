# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crons::RecordCheckIn, type: :service do
  let(:project) { create(:project) }

  it "primo check-in crea il monitor (zero config) con default e stato ok" do
    result = described_class.call(project:, slug: "nightly", name: "Nightly", expected_interval_minutes: 30)

    expect(result).to be_ok
    monitor = project.cron_monitors.sole
    expect(monitor.slug).to eq("nightly")
    expect(monitor.name).to eq("Nightly")
    expect(monitor.expected_interval_minutes).to eq(30)
    expect(monitor).to be_status_ok
    expect(monitor.check_ins.count).to eq(1)
  end

  it "check-in successivo aggiorna last_check_in_at, riazzera missed_alerted_at e resta ok" do
    described_class.call(project:, slug: "nightly")
    monitor = project.cron_monitors.sole
    monitor.update!(status: :missed, missed_alerted_at: Time.current)

    described_class.call(project:, slug: "nightly")

    expect(monitor.reload).to be_status_ok
    expect(monitor.missed_alerted_at).to be_nil
    expect(monitor.check_ins.count).to eq(2)
  end

  it "un check-in arrivato fuori ordine resta nello storico ma non regredisce snapshot e configurazione" do
    newer_at = Time.utc(2026, 7, 13, 20, 2)
    older_at = newer_at - 1.minute
    described_class.call(
      project:, slug: "nightly", expected_interval_minutes: 2, grace_minutes: 1, at: newer_at
    )

    described_class.call(
      project:, slug: "nightly", expected_interval_minutes: 60, grace_minutes: 5, at: older_at
    )

    monitor = project.cron_monitors.sole
    expect(monitor.reload).to have_attributes(
      last_check_in_at: newer_at, expected_interval_minutes: 2, grace_minutes: 1
    )
    expect(monitor.check_ins.order(:checked_in_at).pluck(:checked_in_at)).to eq([ older_at, newer_at ])
  end

  it "configurazione invalida su monitor esistente resta un Result.err senza check-in parziale" do
    described_class.call(project:, slug: "nightly", expected_interval_minutes: 2)
    monitor = project.cron_monitors.sole

    expect do
      @result = described_class.call(project:, slug: "nightly", expected_interval_minutes: 0)
    end.not_to change(monitor.check_ins, :count)

    expect(@result).to be_err
    expect(@result.error.code).to eq("R422-CRON-001")
    expect(monitor.reload.expected_interval_minutes).to eq(2)
  end

  it "status fail viene registrato sul check-in" do
    described_class.call(project:, slug: "nightly", status: "fail", duration_ms: 1200)
    check_in = project.cron_monitors.sole.check_ins.sole
    expect(check_in).to be_status_fail
    expect(check_in.duration_ms).to eq(1200)
  end

  it "slug blank → Result.err R422-CRON-001" do
    result = described_class.call(project:, slug: "")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-CRON-001")
  end

  it "environment per code viene risolto e legato al monitor" do
    env = create(:environment, organization: project.organization, code: "production")
    described_class.call(project:, slug: "nightly", environment: "production")
    expect(project.cron_monitors.sole.environment).to eq(env)
  end
  # CYRA-696 — lo stato del monitor scriveva `ok` a ogni check-in senza guardare com'era andato: un
  # lavoro che parte puntuale e fallisce ogni volta restava verde, e l'unico evento cron esistente
  # (quello mancato) copre il caso opposto.
  describe "lo stato del monitor segue l'esito del check-in (CYRA-696)" do
    it "un check-in fallito non lascia il monitor verde" do
      described_class.call(project:, slug: "nightly")
      expect(project.cron_monitors.sole).to be_status_ok

      described_class.call(project:, slug: "nightly", status: "fail", reason: "disco pieno")

      expect(project.cron_monitors.sole).to be_status_failing
    end

    it "il primo check-in fallito nasce già rosso, non verde" do
      described_class.call(project:, slug: "nightly", status: "fail")
      expect(project.cron_monitors.sole).to be_status_failing
    end

    it "un check-in riuscito dopo un fallimento riporta il monitor verde" do
      described_class.call(project:, slug: "nightly", status: "fail")
      described_class.call(project:, slug: "nightly")

      expect(project.cron_monitors.sole).to be_status_ok
    end

    it "un fallito arrivato fuori ordine non sporca lo stato corrente" do
      newer_at = Time.utc(2026, 7, 13, 20, 2)
      described_class.call(project:, slug: "nightly", at: newer_at)

      described_class.call(project:, slug: "nightly", status: "fail", at: newer_at - 1.minute)

      monitor = project.cron_monitors.sole
      expect(monitor).to be_status_ok
      expect(monitor.check_ins.count).to eq(2)
    end
  end
end
