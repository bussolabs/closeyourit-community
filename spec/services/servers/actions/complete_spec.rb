# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Actions::Complete do
  let(:action) { create(:server_action, status: :running, started_at: Time.current) }

  it "registra un risultato riuscito e tronca l'output" do
    result = described_class.call(action:, status: :succeeded, exit_code: 0,
                                  output: "x" * (Servers::Action::OUTPUT_MAX + 10))
    expect(result).to be_ok
    expect(action.reload).to be_status_succeeded
    expect(action.output.length).to eq(Servers::Action::OUTPUT_MAX)
  end

  it "è idempotente sul retry del risultato" do
    described_class.call(action:, status: :succeeded, exit_code: 0)
    expect(described_class.call(action: action.reload, status: :succeeded, exit_code: 0)).to be_ok
  end

  it "rifiuta una transizione da queued" do
    action.update!(status: :queued)
    expect(described_class.call(action:, status: :succeeded)).not_to be_ok
  end

  # CYRA-809 — l'esito che arriva tardi, dopo che l'azione era già stata dichiarata interrotta:
  # è la ragione per cui "interrotta" non è un esito definitivo. Il server dice com'è andata e la
  # riga smette di essere un punto interrogativo.
  it "accetta l'esito tardivo di un'azione dichiarata interrotta" do
    action.update!(status: :interrupted, finished_at: 1.hour.ago, lease_expires_at: nil)

    result = described_class.call(action:, status: :failed, exit_code: 1, error: "riavvio non riuscito")

    expect(result).to be_ok
    expect(action.reload).to be_status_failed
    expect(action.error).to eq("riavvio non riuscito")
  end

  # Senza il refresh l'esito compare in pagina solo al push successivo dell'agent: fino a un minuto
  # in cui chi ha lanciato l'azione continua a leggere "in corso".
  it "aggiorna la pagina dell'host appena l'esito arriva" do
    allow(Servers::Broadcast).to receive(:refresh)

    described_class.call(action:, status: :succeeded, exit_code: 0)

    expect(Servers::Broadcast).to have_received(:refresh).with(action.host)
  end
end
