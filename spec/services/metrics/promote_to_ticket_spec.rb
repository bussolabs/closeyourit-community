# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::PromoteToTicket, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) do
    create(:metric_group, project:, title: "SELECT * FROM users WHERE id = ?",
                          samples_count: 4, duration_total_ms: 4960.0)
  end

  before { Types::InstallDefaults.call(organization:) }

  it "crea un ticket con uno scenario BDD e collega group.ticket" do
    result = described_class.call(group:, reporter: owner)
    expect(result).to be_ok
    ticket = result.value
    expect(ticket.title).to eq("SELECT * FROM users WHERE id = ?")
    scenario = ticket.scenarios.sole
    expect(scenario.step_when).to eq("SELECT * FROM users WHERE id = ?")
    expect(scenario.step_then).to include("1240ms", "4 occurrences") # avg 4960/4 = 1240
    expect(scenario.step_expected).to eq("Should complete within budget.")
    expect(group.reload.ticket).to eq(ticket)
    expect(group).to be_promoted
  end

  it "default status open + priority high" do
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.status.code).to eq("open")
    expect(ticket.priority.code).to eq("high")
  end

  it "l'analisi tecnica riassume environment + db_system dall'ultima occorrenza" do
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago,
                           environment: "production", payload: { "db_system" => "postgresql" })
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.technical_analysis).to include("production", "postgresql")
  end

  # Come per gli errori: i metadati vengono dall'ingest e non hanno tetto, la promozione non deve
  # fallire per un db_system abnorme.
  it "metadati d'ingest lunghissimi → analisi troncata, promozione riuscita" do
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago,
                           environment: "production", payload: { "db_system" => "p" * 5_000 })

    result = described_class.call(group:, reporter: owner)

    expect(result).to be_ok
    expect(result.value.technical_analysis.length)
      .to eq(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
  end

  it "scenario given fisso e analisi tecnica nil quando non ci sono occorrenze" do
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.scenarios.sole.step_given).to eq("Reported from performance monitoring.")
    expect(ticket.technical_analysis).to be_nil
  end

  it "scenario given fisso e analisi tecnica nil quando l'occorrenza non ha metadati (env/db assenti)" do
    create(:metric_sample, group:, project:, occurred_at: 1.minute.ago, environment: nil, payload: {})
    ticket = described_class.call(group:, reporter: owner).value
    expect(ticket.scenarios.sole.step_given).to eq("Reported from performance monitoring.")
    expect(ticket.technical_analysis).to be_nil
  end

  it "gruppo già promosso → err R422-METRIC-001, nessun secondo ticket" do
    described_class.call(group:, reporter: owner)
    expect do
      result = described_class.call(group:, reporter: owner)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-METRIC-001")
    end.not_to change(Ticketing::Ticket, :count)
  end

  it "reporter senza accesso al progetto → propaga R404-TICKET-001 (CreateTicket scoping)" do
    member = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
    result = described_class.call(group:, reporter: member) # member non assegnato al progetto
    expect(result).to be_err
    expect(result.error.code).to eq("R404-TICKET-001")
    expect(group.reload).not_to be_promoted
  end
end

# Org SENZA i lookup default 'open'/'high' → il promote ricade sul primo status/priority attivo.
RSpec.describe Metrics::PromoteToTicket, "fallback lookup", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) { create(:metric_group, project:, title: "Q") }

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
# (rami else di `&.id`). CreateTicket rifiuta senza status/priority → Result.err.
RSpec.describe Metrics::PromoteToTicket, "senza lookup (safe-nav &.id else)", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) { create(:metric_group, project:) }

  it "status_id/priority_id nil quando l'org non ha status/priority → err" do
    result = described_class.call(group:, reporter: owner)
    expect(result).to be_err
    expect(group.reload).not_to be_promoted
  end
end

# CYRA-47: promote idempotente sotto concorrenza. Doppio click / retry di rete → due richieste che
# vedono ticket_id=nil NON devono creare due ticket. Difesa a due strati: with_lock (serializza +
# re-check dopo il lock) e indice unico parziale su metrics_groups.ticket_id (invariante 1:1 in DB).
RSpec.describe Metrics::PromoteToTicket, "idempotenza sotto concorrenza (CYRA-47)", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:group) do
    create(:metric_group, project:, title: "SELECT * FROM users WHERE id = ?",
                          samples_count: 4, duration_total_ms: 4960.0)
  end

  before { Types::InstallDefaults.call(organization:) }

  it "una seconda promote su un'istanza stale (finestra di race) non crea un secondo ticket" do
    stale = Metrics::Group.find(group.id) # istanza con ticket_id=nil in memoria, come la richiesta in ritardo

    first = described_class.call(group:, reporter: owner) # l'altra richiesta vince e promuove nel DB
    expect(first).to be_ok
    expect(stale.promoted?).to be(false) # vista stale ottimista: il check pre-lock passerebbe

    expect do
      result = described_class.call(group: stale, reporter: owner)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-METRIC-001")
    end.not_to change(Ticketing::Ticket, :count) # il re-check dentro with_lock blocca il secondo ticket

    expect(group.reload.ticket).to eq(first.value) # il primo ticket resta collegato, non orfano
  end

  it "l'indice unico parziale rifiuta due gruppi collegati allo stesso ticket" do
    ticket = described_class.call(group:, reporter: owner).value
    other = create(:metric_group, project:)

    expect { other.update_column(:ticket_id, ticket.id) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "l'indice parziale non vincola i gruppi non promossi: più ticket_id nil coesistono" do
    create(:metric_group, project:)
    expect { create(:metric_group, project:) }.not_to raise_error
  end
end
