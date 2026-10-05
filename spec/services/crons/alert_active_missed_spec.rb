# frozen_string_literal: true

require "rails_helper"

# CYRA-477 Scenario 3: quando la copertura "cron mancato" viene attivata (creata/abilitata la regola),
# i job GIÀ fermi devono ricevere subito l'avviso — non aspettare di recuperare e ricadere.
RSpec.describe Crons::AlertActiveMissed, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  it "avvisa i cron già missed coperti da una regola cron_missed org-wide" do
    missed = create(:cron_monitor, project:, status: :missed, last_check_in_at: 4.days.ago)
    create(:cron_monitor, project:, status: :ok, last_check_in_at: 1.minute.ago) # non missed → ignorato
    rule = create(:alerting_rule, organization:, event_type: :cron_missed)

    expect { described_class.call(organization:, rule:) }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "cron_missed", subject_type: "Crons::Monitor",
                           subject_id: missed.id, project_id: project.id))
  end

  it "non avvisa nulla se la regola non è cron_missed" do
    create(:cron_monitor, project:, status: :missed)
    rule = create(:alerting_rule, :uptime_down, organization:)

    expect { described_class.call(organization:, rule:) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "non avvisa nulla se la regola è disabilitata" do
    create(:cron_monitor, project:, status: :missed)
    rule = create(:alerting_rule, :disabled, organization:, event_type: :cron_missed)

    expect { described_class.call(organization:, rule:) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "ignora i cron disabilitati anche se in stato missed" do
    create(:cron_monitor, project:, status: :missed, enabled: false)
    rule = create(:alerting_rule, organization:, event_type: :cron_missed)

    expect { described_class.call(organization:, rule:) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "una regola scoped su un progetto avvisa solo i cron di quel progetto" do
    other = create(:project, organization:)
    mine = create(:cron_monitor, project:, status: :missed, last_check_in_at: 1.day.ago)
    theirs = create(:cron_monitor, project: other, status: :missed, last_check_in_at: 1.day.ago)
    rule = create(:alerting_rule, organization:, event_type: :cron_missed, project:)

    described_class.call(organization:, rule:)

    expect(Alerting::EvaluateJob).to have_been_enqueued.with(hash_including(subject_id: mine.id))
    expect(Alerting::EvaluateJob).not_to have_been_enqueued.with(hash_including(subject_id: theirs.id))
  end

  it "ritorna il numero di cron avvisati" do
    create(:cron_monitor, project:, status: :missed)
    rule = create(:alerting_rule, organization:, event_type: :cron_missed)

    result = described_class.call(organization:, rule:)

    expect(result).to be_ok
    expect(result.value).to eq(1)
  end
end
