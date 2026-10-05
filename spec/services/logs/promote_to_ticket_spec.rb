# frozen_string_literal: true

require "rails_helper"

# CYRA-347 — il ticket che nasce da un messaggio. Qui stanno i casi che la pagina non mostra: cosa
# succede quando il ticket non si può creare, e con quali stato e priorità nasce in un'organizzazione
# che non ha i codici di default.
RSpec.describe Logs::PromoteToTicket do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:reporter) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
  end

  def entry(**attrs)
    create(:log_entry, project:, level: :error, message: "Domain not verified", **attrs)
  end

  it "il registro tecnico porta tutto il contesto che c'è" do
    Types::InstallDefaults.call(organization:)
    riga = entry(environment: "production", release: "v1.4.2", logger_name: "Resend", trace_id: "abc123")

    esito = described_class.call(entry: riga, reporter:).value

    expect(esito.ticket.technical_analysis).to include("production").and include("v1.4.2")
      .and include("Resend").and include("abc123")
  end

  # Un'organizzazione senza i codici canonici non deve impedire la promozione: si ripiega sul primo
  # stato e sulla prima priorità attivi, che è meglio di un errore in faccia.
  it "senza i codici di default ripiega sul primo stato e sulla prima priorità" do
    create(:ticket_status, organization:, code: "backlog")
    create(:ticket_priority, organization:, code: "normale")

    esito = described_class.call(entry: entry, reporter:).value

    expect(esito.ticket.status.code).to eq("backlog")
    expect(esito.ticket.priority.code).to eq("normale")
  end

  it "riusa il ticket di un messaggio identico e lo dichiara" do
    Types::InstallDefaults.call(organization:)
    primo = described_class.call(entry: entry, reporter:).value
    gemello = entry

    esito = described_class.call(entry: gemello, reporter:).value

    expect(esito.ticket).to eq(primo.ticket)
    expect(esito.reused).to be(true)
    expect(primo.reused).to be(false)
  end

  # Se il ticket non si può creare, l'errore torna com'è: nessun collegamento a metà, nessun falso ok.
  it "se il ticket non nasce, l'errore torna intatto e non si collega niente" do
    Types::InstallDefaults.call(organization:)
    riga = entry
    allow(Ticketing::CreateTicket).to receive(:call).and_return(
      Result.err(AppError.new("no", code: "R422-TICKET-001"))
    )

    esito = described_class.call(entry: riga, reporter:)

    expect(esito).not_to be_ok
    expect(riga.reload.links).to be_empty
  end
end
