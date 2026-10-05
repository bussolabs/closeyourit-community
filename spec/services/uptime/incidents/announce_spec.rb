# frozen_string_literal: true

require "rails_helper"

# CYRA-792 — il punto unico da cui parte un avviso di incident: lo usano il controllo che registra il
# cambio di stato e il giro di recupero, e la regola di «una volta sola» dev'essere la stessa.
RSpec.describe Uptime::Incidents::Announce, type: :service do
  let(:monitor) { create(:uptime_monitor) }
  let(:incident) { create(:uptime_incident, :down_alert_pending, monitor:) }

  it "accoda l'avviso con la rotta del monitor e segna la consegna" do
    expect { described_class.call(incident:, event_type: "uptime_down") }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "uptime_down", subject_type: "Uptime::Incident",
                           subject_id: incident.id, project_id: monitor.project_id,
                           environment_id: monitor.environment_id))
    expect(incident.reload.down_alerted_at).to be_present
  end

  it "dice di aver annunciato" do
    expect(described_class.call(incident:, event_type: "uptime_down").value).to be(true)
  end

  it "una seconda chiamata non ri-accoda e dice di non aver annunciato" do
    described_class.call(incident:, event_type: "uptime_down")

    expect { expect(described_class.call(incident:, event_type: "uptime_down").value).to be(false) }
      .not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  # Il segno segue l'accodamento: se la coda non accetta l'avviso, la riga resta da consegnare.
  it "un accodamento fallito lascia l'incident pendente" do
    allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")

    expect { described_class.call(incident:, event_type: "uptime_down") }.to raise_error(StandardError)
    expect(incident.reload.down_alerted_at).to be_nil
  end

  it "il ripristino usa la propria colonna" do
    risolto = create(:uptime_incident, :up_alert_pending, monitor:, resolved_at: 5.minutes.ago)

    described_class.call(incident: risolto, event_type: "uptime_up")
    expect(risolto.reload.up_alerted_at).to be_present
    expect(risolto.down_alerted_at).to be_present # invariato: era già annunciato
  end
end
