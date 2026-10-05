# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::PromoteToTicket, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) { create(:error_group, project:, title: "RuntimeError: boom", culprit: "App::Widget#render") }

  before { Types::InstallDefaults.call(organization:) }

  it "crea un ticket con uno scenario BDD e collega group.ticket" do
    result = described_class.call(group:, reporter: owner)
    expect(result).to be_ok
    ticket = result.value
    # CYRA-399 — il titolo non è più il messaggio grezzo: quello resta nel corpo.
    expect(ticket.title).to eq("Error: RuntimeError · App::Widget#render")
    expect(ticket.description).to include("RuntimeError: boom")
    scenario = ticket.scenarios.sole
    expect(scenario.step_when).to eq("App::Widget#render")
    expect(scenario.step_expected).to eq("No exception should be raised.")
    expect(group.reload.ticket).to eq(ticket)
    expect(group).to be_promoted
  end

  it "default status open + priority high" do
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.status.code).to eq("open")
    expect(ticket.priority.code).to eq("high")
  end

  it "l'analisi tecnica riassume env/release/server dall'ultimo evento" do
    create(:error_event, group:, project:, occurred_at: 1.minute.ago,
           environment: "production", release: "v1.2.3", server_name: "web-1")
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.technical_analysis).to include("production", "v1.2.3", "web-1")
  end

  it "gruppo già promosso → err R422-ERROR-001, nessun secondo ticket" do
    described_class.call(group:, reporter: owner)
    expect do
      result = described_class.call(group:, reporter: owner)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ERROR-001")
    end.not_to change(Ticketing::Ticket, :count)
  end

  it "reporter senza accesso al progetto → propaga R404-TICKET-001 (CreateTicket scoping)" do
    member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
    result = described_class.call(group:, reporter: member)   # member non assegnato al progetto
    expect(result).to be_err
    expect(result.error.code).to eq("R404-TICKET-001")
    expect(group.reload).not_to be_promoted
  end

  it "analisi tecnica con solo runtime (niente env/release/server)" do
    create(:error_event, group:, project:, occurred_at: 1.minute.ago,
           environment: nil, release: nil, server_name: nil, runtime: "ruby 3.3.10")
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.technical_analysis).to eq("Runtime: ruby 3.3.10")
  end

  # I metadati arrivano dall'ingest e non hanno tetto: la promozione non deve fallire per un release
  # abnorme — chi promuove non può comunque correggere i dati dell'errore.
  it "metadati d'ingest lunghissimi → analisi troncata, promozione riuscita" do
    create(:error_event, group:, project:, occurred_at: 1.minute.ago,
           environment: "production", release: "v" * 5_000, server_name: "web-1")

    result = described_class.call(group:, reporter: owner)

    expect(result).to be_ok
    expect(result.value.technical_analysis.length)
      .to eq(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
  end

  it "scenario given fisso e analisi tecnica nil quando l'ultimo evento non ha metadati" do
    create(:error_event, group:, project:, occurred_at: 1.minute.ago,
           environment: nil, release: nil, server_name: nil, runtime: nil)
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.scenarios.sole.step_given).to eq("Reported from error monitoring.")
    expect(ticket.technical_analysis).to be_nil
  end
end

# Org SENZA i lookup default 'open'/'high' → il promote ricade sul primo status/priority attivo.
RSpec.describe Errors::PromoteToTicket, "fallback lookup", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) { create(:error_group, project:, title: "E", culprit: "c") }

  before do
    create(:ticket_status, organization:, code: "todo", position: 0)
    create(:ticket_priority, organization:, code: "p1", position: 0)
  end

  it "usa il primo status/priority attivo come fallback" do
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.status.code).to eq("todo")
    expect(ticket.priority.code).to eq("p1")
  end
end

# Org SENZA alcun status/priority → default_status/default_priority nil → status_id/priority_id nil
# (rami else di `&.id`). CreateTicket rifiuta un ticket senza status/priority → Result.err.
RSpec.describe Errors::PromoteToTicket, "senza lookup (safe-nav &.id else)", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) { create(:error_group, project:, title: "E", culprit: "c") }

  it "status_id/priority_id nil quando l'org non ha status/priority → err" do
    result = described_class.call(group:, reporter: owner)
    expect(result).to be_err
    expect(group.reload).not_to be_promoted
  end
end

# CYRA-47: promote idempotente sotto concorrenza. Doppio click / retry di rete → due richieste che
# vedono ticket_id=nil NON devono creare due ticket. Difesa a due strati: with_lock (serializza +
# re-check dopo il lock) e indice unico parziale su errors_groups.ticket_id (invariante 1:1 in DB).
RSpec.describe Errors::PromoteToTicket, "idempotenza sotto concorrenza (CYRA-47)", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) { create(:error_group, project:, title: "RuntimeError: boom", culprit: "c") }

  before { Types::InstallDefaults.call(organization:) }

  it "una seconda promote su un'istanza stale (finestra di race) non crea un secondo ticket" do
    stale = Errors::Group.find(group.id) # istanza con ticket_id=nil in memoria, come la richiesta in ritardo

    first = described_class.call(group:, reporter: owner) # l'altra richiesta vince e promuove nel DB
    expect(first).to be_ok
    expect(stale.promoted?).to be(false) # vista stale ottimista: il check pre-lock passerebbe

    expect do
      result = described_class.call(group: stale, reporter: owner)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-ERROR-001")
    end.not_to change(Ticketing::Ticket, :count) # il re-check dentro with_lock blocca il secondo ticket

    expect(group.reload.ticket).to eq(first.value) # il primo ticket resta collegato, non orfano
  end

  it "l'indice unico parziale rifiuta due gruppi collegati allo stesso ticket" do
    ticket = described_class.call(group:, reporter: owner).value
    other = create(:error_group, project:)

    expect { other.update_column(:ticket_id, ticket.id) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "l'indice parziale non vincola i gruppi non promossi: più ticket_id nil coesistono" do
    create(:error_group, project:)
    expect { create(:error_group, project:) }.not_to raise_error
  end
  # CYRA-399 — il titolo del gruppo è il messaggio dell'eccezione: finiva tale e quale in cima alla
  # colonna più letta, alto quattro righe, accanto a titoli scritti da persone.
  describe "titolo leggibile" do
    def promote(title:, culprit: nil)
      subject_group = create(:error_group, project:, title:, culprit:)
      described_class.call(group: subject_group, reporter: owner).value
    end

    it "riconosce le famiglie di errore più comuni" do
      ticket = promote(title: 'ActiveRecord::ConnectionNotEstablished: connection to server at "10.0.0.5", port 5432 failed')

      expect(ticket.title).to eq(I18n.t("errors.ticket_title.families.database_down"))
      expect(ticket.title.length).to be <= Errors::TicketTitle::MAX
    end

    it "una famiglia sconosciuta ricade sul nome dell'eccezione, non su una frase inventata" do
      ticket = promote(title: "Acme::WeirdFailure: something odd")

      expect(ticket.title).to eq(I18n.t("errors.ticket_title.fallback", type: "WeirdFailure"))
    end

    it "aggiunge il punto in cui è successo, in forma corta" do
      ticket = promote(title: "Timeout::Error: execution expired", culprit: "app/services/checkout/pay.rb in call")

      expect(ticket.title).to include(I18n.t("errors.ticket_title.families.timeout"), "pay.rb", "call")
      expect(ticket.title).not_to include("app/services")
    end

    it "il messaggio tecnico integrale resta nel corpo del ticket" do
      ticket = promote(title: "PG::UnableToSend: server closed the connection unexpectedly",
                       culprit: "app/models/order.rb in save!")

      expect(ticket.description).to include("PG::UnableToSend: server closed the connection unexpectedly")
      expect(ticket.description).to include("app/models/order.rb in save!")
    end

    it "un titolo lunghissimo non sfonda il campo" do
      ticket = promote(title: "Acme::Boom: #{'x' * 500}")

      expect(ticket.title.length).to be <= Errors::TicketTitle::MAX
    end
  end
end
