# frozen_string_literal: true

require "rails_helper"

# CYRA-823 — chi ha la scheda di un agente aperta la vede cambiare senza ricaricarla. Qui si prova
# COSA viaggia: un segnale, non una pagina. È il vincolo che rende sicuro uno stream condiviso da
# persone con visibilità diverse sui progetti.
RSpec.describe Agents::Hosts::Broadcast do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:stream) { Realtime::Streams.agent_host(host) }

  # In test la cache è null_store (ogni write "riesce") → il throttle non si vedrebbe.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  it "avvisa chi guarda la scheda di QUELLA macchina" do
    expect { described_class.activity(host) }.to have_broadcasted_to(stream).once
  end

  it "chiede di ricaricare il solo riquadro dell'attività, non la pagina intera" do
    expect { described_class.activity(host) }
      .to have_broadcasted_to(stream)
      .with(a_string_including('action="refresh_frame"', 'target="host-activity"'))
  end

  # IL punto: `agents.view` è di organizzazione, i ticket si vedono per progetto. Un messaggio con
  # dentro l'attività renderizzata consegnerebbe a tutti i titoli dei ticket di progetti che non
  # vedono — e il mittente non ha modo di sapere per chi sta rendendo.
  it "non porta con sé niente da leggere: nessun ticket, nessun titolo" do
    ticket = create(:ticket, organization:, title: "Titolo riservato")
    host.update!(active_runs: [ { "ticket" => ticket.code, "phase" => "verifying" } ])

    expect { described_class.activity(host) }
      .to have_broadcasted_to(stream)
      .with(satisfy { |payload| !payload.to_s.include?(ticket.code) && !payload.to_s.include?("Titolo riservato") })
  end

  it "una raffica di battiti non diventa una raffica di segnali" do
    described_class.activity(host) # il primo passa subito

    expect { 20.times { described_class.activity(host) } }
      .to have_enqueued_job(Realtime::BroadcastRefreshJob).exactly(:once)
  end

  it "il segnale differito resta ristretto al riquadro dell'attività" do
    expect { Realtime::BroadcastRefreshJob.perform_now(stream, described_class::ACTIVITY_FRAME) }
      .to have_broadcasted_to(stream).with(a_string_including('action="refresh_frame"'))
  end

  it "due macchine, due stream distinti" do
    altra = create(:agent_host, organization:)

    expect { described_class.activity(host) }
      .not_to have_broadcasted_to(Realtime::Streams.agent_host(altra))
  end
end
