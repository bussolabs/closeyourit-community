# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ResolveDuplicate do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:reporter) { create(:account) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }

  before do
    create(:membership, account: reporter, organization: org, role: :member)
    create(:project_membership, account: reporter, project: project)
  end

  def base_params(overrides = {})
    { project_id: project.id, title: "Crash al login", kind: "bug",
      description: "Login esplode su submit",
      status_id: status.id, priority_id: priority.id }.merge(overrides)
  end

  def call_service(ack:, **kwargs)
    described_class.call(organization: org, reporter: reporter, params: base_params, ack: ack, **kwargs)
  end

  describe "ack=create (crea comunque con motivazione)" do
    it "senza motivazione ritorna err R422-TICKET-009 e non crea nulla" do
      result = nil
      expect { result = call_service(ack: "create", reason: "  ") }
        .not_to change(Ticketing::Ticket, :count)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-009")
    end

    it "crea il ticket appendendo la motivazione alla descrizione" do
      result = call_service(ack: "create", reason: "Il vecchio riguarda un altro endpoint")

      expect(result).to be_ok
      ticket = result.value
      expect(ticket.description).to start_with("Login esplode su submit")
      expect(ticket.description).to include("Il vecchio riguarda un altro endpoint")
      expect(ticket.description).to include("---")
      expect(ticket.comments).to be_empty
    end

    # La motivazione la appende il sistema: una descrizione già al limite non deve impedire la
    # creazione né essere tagliata. Il ticket nasce intatto e la motivazione va in un commento.
    it "descrizione al limite → ticket creato con descrizione intatta e motivazione in un commento" do
      al_limite = "x" * Ticketing::Constants::DESCRIPTION_MAX_CHARS
      result = described_class.call(organization: org, reporter: reporter,
                                    params: base_params(description: al_limite),
                                    ack: "create", reason: "Riguarda un altro endpoint")

      expect(result).to be_ok
      ticket = result.value
      expect(ticket.description).to eq(al_limite)
      expect(ticket.comments.first.body).to include("Riguarda un altro endpoint")
    end

    it "nel commento la motivazione finisce INTERA: lì il tetto della descrizione non vale" do
      motivazione = "m" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 1_000)
      result = described_class.call(organization: org, reporter: reporter,
                                    params: base_params(description: "Corpo breve"),
                                    ack: "create", reason: motivazione)

      expect(result).to be_ok
      ticket = result.value
      expect(ticket.description).to eq("Corpo breve")
      expect(ticket.comments.first.body).to include(motivazione)
    end

    it "senza descrizione il corpo non resta vuoto: motivazione accorciata nel corpo, intera nel commento" do
      motivazione = "m" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 1_000)
      result = described_class.call(organization: org, reporter: reporter,
                                    params: base_params(description: ""),
                                    ack: "create", reason: motivazione)

      expect(result).to be_ok
      ticket = result.value
      expect(ticket.description.length).to eq(Ticketing::Constants::DESCRIPTION_MAX_CHARS)
      expect(ticket.comments.first.body).to include(motivazione)
    end

    # I CRLF del browser spariscono nella normalizzazione: misurando la lunghezza grezza si
    # sposterebbe in un commento una motivazione che invece nella descrizione ci sta.
    it "misura lo spazio dopo la normalizzazione dei fine-riga, non prima" do
      righe = ("riga\r\n" * 600).chomp("\r\n") # 3.598 grezzi, 2.998 normalizzati
      result = described_class.call(organization: org, reporter: reporter,
                                    params: base_params(description: righe),
                                    ack: "create", reason: "x" * 800)

      expect(result).to be_ok
      ticket = result.value
      expect(ticket.description).to include("x" * 800) # la motivazione è NEL corpo
      expect(ticket.comments).to be_empty
    end
  end

  describe "ack=link (crea e collega al precedente)" do
    let!(:old_ticket) { create(:ticket, organization: org, project: project, title: "Login rotto") }

    it "crea ticket + link duplicate + evento linked su entrambi, senza commento se assente" do
      result = nil
      expect { result = call_service(ack: "link", link_ticket_ids: [ old_ticket.id ], link_kind: "duplicate") }
        .to change(Connections::TicketLink, :count).by(1)
        .and not_change(Ticketing::Comment, :count)

      expect(result).to be_ok
      link = Connections::TicketLink.last
      expect(link.ticket).to eq(result.value)
      expect(link.related).to eq(old_ticket)
      expect(link.kind).to eq("duplicate")
      expect(link.created_by).to eq(reporter)

      expect(result.value.events.pluck(:action)).to include("linked")
      expect(old_ticket.events.pluck(:action)).to include("linked")
    end

    it "collega tutti i bersagli spuntati, con il commento su ognuno" do
      second = create(:ticket, organization: org, project: project, title: "Login rotto anche da mobile")

      result = nil
      expect { result = call_service(ack: "link", link_ticket_ids: [ old_ticket.id, second.id ],
                                     link_kind: "related", link_comment: "Stesso sintomo") }
        .to change(Connections::TicketLink, :count).by(2)

      expect(result).to be_ok
      expect(result.value.links.map(&:related)).to match_array([ old_ticket, second ])
      expect(old_ticket.comments.last.body).to eq("Stesso sintomo")
      expect(second.comments.last.body).to eq("Stesso sintomo")
    end

    it "con commento opzionale lo aggiunge al ticket preesistente" do
      result = call_service(ack: "link", link_ticket_ids: [ old_ticket.id ], link_kind: "related",
                            link_comment: "Visto anche su iOS 19")

      expect(result).to be_ok
      comment = old_ticket.comments.last
      expect(comment.body).to eq("Visto anche su iOS 19")
      expect(comment.author).to eq(reporter)
      expect(Connections::TicketLink.last.kind).to eq("related")
    end

    it "target di un altro progetto (anche visibile) → err R404-TICKET-003, nessun ticket creato" do
      other_project = create(:project, organization: org)
      create(:project_membership, account: reporter, project: other_project)
      foreign = create(:ticket, organization: org, project: other_project)

      result = nil
      expect { result = call_service(ack: "link", link_ticket_ids: [ foreign.id ], link_kind: "duplicate") }
        .not_to change(Ticketing::Ticket, :count)
      expect(result).to be_err
      expect(result.error.code).to eq("R404-TICKET-003")
    end

    it "target non visibile (progetto senza membership) → err R404-TICKET-003 (anti-BOLA)" do
      hidden_project = create(:project, organization: org)
      hidden = create(:ticket, organization: org, project: hidden_project)

      # Il draft punta al progetto nascosto: né il progetto né il target sono raggiungibili.
      result = described_class.call(organization: org, reporter: reporter,
                                    params: base_params(project_id: hidden_project.id),
                                    ack: "link", link_ticket_ids: [ hidden.id ], link_kind: "duplicate")
      expect(result).to be_err
    end

    it "kind invalido → err R422-TICKET-010" do
      result = call_service(ack: "link", link_ticket_ids: [ old_ticket.id ], link_kind: "banana")
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-010")
    end
  end

  it "ack sconosciuto → err R422-TICKET-011" do
    result = call_service(ack: "boh")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-011")
  end
end
