# frozen_string_literal: true

require "rails_helper"

# CYRA-809 — l'azione partita e mai conclusa. Prima di questo servizio restava "in corso" per sempre
# e teneva occupato l'unico posto attivo per host: nessun'altra azione poteva più partire.
RSpec.describe Servers::Actions::Reconcile do
  let(:host) { create(:server_host) }
  let(:grace) { Servers::Constants::ACTION_ORPHAN_AFTER_SECONDS }

  # Un'azione presa in carico, la cui autorizzazione è scaduta e la cui lease tace da oltre la grazia.
  def orphan(**overrides)
    create(:server_action, host:, organization: host.organization, status: :running,
           started_at: 3.hours.ago, expires_at: 2.hours.ago,
           lease_expires_at: (grace + 60).seconds.ago, **overrides)
  end

  it "chiude come interrotta l'azione partita e mai conclusa" do
    action = orphan

    expect(described_class.call(host:).value).to eq(1)
    expect(action.reload).to be_status_interrupted
    expect(action.finished_at).to be_present
    expect(action.lease_expires_at).to be_nil
  end

  it "libera il posto: dopo la riconciliazione una nuova azione può essere accodata" do
    orphan

    expect do
      host.actions.create!(organization: host.organization, kind: "reboot",
                           idempotency_key: SecureRandom.uuid, expires_at: 1.hour.from_now)
    end.to raise_error(ActiveRecord::RecordNotUnique)

    described_class.call(host:)

    expect do
      host.actions.create!(organization: host.organization, kind: "reboot",
                           idempotency_key: SecureRandom.uuid, expires_at: 1.hour.from_now)
    end.not_to raise_error
  end

  # Il punto del ticket: un intervento dall'esito incerto non si ripete da solo. Riavviare due volte
  # un server perché il primo riavvio non ha fatto in tempo a raccontarsi è peggio del blocco.
  it "non rimette in coda l'azione interrotta" do
    action = orphan(kind: "reboot")

    described_class.call(host:)

    expect(action.reload).not_to be_status_queued
    expect(host.actions.active).to be_empty
  end

  # La lease dura due minuti e nessuno la rinnova: la sua scadenza da sola non prova che il comando
  # sia finito. Dentro la grazia l'azione è considerata viva e non si tocca.
  it "non tocca un'azione la cui lease è scaduta da poco: potrebbe essere ancora in corso" do
    action = orphan(lease_expires_at: 1.minute.ago)

    expect(described_class.call(host:).value).to eq(0)
    expect(action.reload).to be_status_running
  end

  # Dentro la finestra di autorizzazione il recupero resta quello di sempre: la ripesca il claim.
  it "non tocca un'azione ancora dentro la sua finestra di autorizzazione" do
    action = orphan(expires_at: 30.minutes.from_now)

    expect(described_class.call(host:).value).to eq(0)
    expect(action.reload).to be_status_running
  end

  # Una running senza lease (dato incoerente di una riga vecchia) sarebbe rimasta bloccata per sempre:
  # il confronto cade su started_at, non sul solo campo che può essere vuoto.
  it "chiude anche una running rimasta senza lease" do
    action = orphan(lease_expires_at: nil)

    expect(described_class.call(host:).value).to eq(1)
    expect(action.reload).to be_status_interrupted
  end

  it "scade le azioni mai prese in carico e ormai fuori tempo" do
    action = create(:server_action, host:, organization: host.organization, expires_at: 1.minute.ago)

    expect(described_class.call(host:).value).to eq(1)
    expect(action.reload).to be_status_expired
  end

  it "è idempotente: un secondo giro non trova più niente da chiudere" do
    orphan
    described_class.call(host:)

    expect(described_class.call(host:).value).to eq(0)
  end

  it "senza host guarda tutta la flotta" do
    orphan
    other = create(:server_action, status: :running, started_at: 3.hours.ago, expires_at: 2.hours.ago,
                   lease_expires_at: (grace + 60).seconds.ago)

    expect(described_class.call.value).to eq(2)
    expect(other.reload).to be_status_interrupted
  end

  it "non tocca gli altri host quando gli si chiede un host solo" do
    other = create(:server_action, status: :running, started_at: 3.hours.ago, expires_at: 2.hours.ago,
                   lease_expires_at: (grace + 60).seconds.ago)

    described_class.call(host:)

    expect(other.reload).to be_status_running
  end

  # Chi ha lanciato l'azione sta guardando la pagina: "in corso" deve smettere di dirlo da solo.
  it "aggiorna la pagina dell'host quando chiude qualcosa" do
    orphan
    allow(Servers::Broadcast).to receive(:refresh)

    described_class.call(host:)

    expect(Servers::Broadcast).to have_received(:refresh).with(host)
  end

  it "non manda aggiornamenti quando non c'è niente da chiudere" do
    allow(Servers::Broadcast).to receive(:refresh)

    described_class.call(host:)

    expect(Servers::Broadcast).not_to have_received(:refresh)
  end
end
