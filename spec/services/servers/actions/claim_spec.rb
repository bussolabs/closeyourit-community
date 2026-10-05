# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Actions::Claim do
  let(:host) { create(:server_host) }

  it "consegna una sola azione e le assegna una lease" do
    action = create(:server_action, host:, organization: host.organization)
    result = described_class.call(host:, now: Time.current)

    expect(result.value).to eq(action)
    expect(action.reload).to be_status_running
    expect(action.lease_expires_at).to be_present
    expect(described_class.call(host:).value).to be_nil
  end

  it "scade le azioni vecchie senza consegnarle" do
    action = create(:server_action, host:, organization: host.organization, expires_at: 1.second.ago)

    expect(described_class.call(host:).value).to be_nil
    expect(action.reload).to be_status_expired
  end

  it "non consegna azioni di un altro host" do
    create(:server_action)
    expect(described_class.call(host:).value).to be_nil
  end

  it "recupera una lease scaduta dopo il crash dell'agent" do
    action = create(:server_action, host:, organization: host.organization, status: :running,
                    started_at: 3.minutes.ago, lease_expires_at: 1.minute.ago)
    expect(described_class.call(host:).value).to eq(action)
    expect(action.reload).to be_status_running
  end

  # CYRA-809 — l'azione partita e mai conclusa teneva occupato per sempre l'unico posto attivo:
  # nessun claim successivo poteva consegnare niente, su quell'host.
  context "quando un'azione è rimasta in corso oltre la sua scadenza" do
    let(:grace) { Servers::Constants::ACTION_ORPHAN_AFTER_SECONDS }
    let!(:orphan) do
      create(:server_action, host:, organization: host.organization, status: :running, kind: "reboot",
             started_at: 3.hours.ago, expires_at: 2.hours.ago, lease_expires_at: (grace + 60).seconds.ago)
    end

    it "la chiude come interrotta invece di lasciarla in corso" do
      described_class.call(host:)

      expect(orphan.reload).to be_status_interrupted
    end

    # Non si ripete un intervento dall'esito incerto: il riavvio di prima non torna in coda da solo.
    it "non la riconsegna all'agent" do
      expect(described_class.call(host:).value).to be_nil
    end

    # Il posto torna libero: prima della riconciliazione l'orfana lo occupava e nessuna azione nuova
    # poteva nemmeno essere accodata.
    it "lascia accodare e partire l'azione richiesta dopo di lei" do
      described_class.call(host:)

      successiva = create(:server_action, host:, organization: host.organization)

      expect(described_class.call(host:).value).to eq(successiva)
    end
  end

  # "In attesa" deve diventare "in corso" quando l'agent la prende, non al push successivo.
  it "aggiorna la pagina dell'host quando consegna un'azione" do
    create(:server_action, host:, organization: host.organization)
    allow(Servers::Broadcast).to receive(:refresh)

    described_class.call(host:)

    expect(Servers::Broadcast).to have_received(:refresh).with(host)
  end

  it "non manda aggiornamenti quando non c'è niente da consegnare" do
    allow(Servers::Broadcast).to receive(:refresh)

    described_class.call(host:)

    expect(Servers::Broadcast).not_to have_received(:refresh)
  end
end
