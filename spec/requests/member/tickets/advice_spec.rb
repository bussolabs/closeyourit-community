# frozen_string_literal: true

require "rails_helper"

# Il giro completo di un consiglio (CYRA-264): scritto in un testo lungo → mostrato in un riquadro
# proprio → un link che apre la creazione già compilata → i due ticket restano collegati.
#
# Il parser sta in spec/services/ticketing/advice_lines_spec.rb; qui si prova ciò che il parser da
# solo non dice: che il riquadro compaia solo quando serve, che il link porti davvero i valori, e
# che il collegamento si scriva senza poter far fallire la creazione.
RSpec.describe "Member — consigli di un ticket", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:status) { create(:ticket_status, organization: organization) }
  let(:priority) { create(:ticket_priority, organization: organization) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: member, organization: organization, role: :member)
    # Scoping: un member vede e apre ticket solo sui progetti a cui è assegnato.
    create(:project_membership, account: member, project: project)
  end

  let(:advice) { "Il contatore manca sulla casella del resoconto: nessuno sa quando esagera." }
  let(:analysis) { "**Approccio:** qualcosa.\n\n**Consigli:**\n- #{advice}" }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  describe "il riquadro sulla scheda del ticket" do
    it "mostra un consiglio scritto nell'analisi tecnica, col suo link" do
      ticket = create(:ticket, organization: organization, project: project, technical_analysis: analysis)
      sign_in(member)
      get member_ticket_path(ticket)

      expect(html.css('[data-test="ticket-advice-line"]').length).to eq(1)
      link = html.at_css('[data-test="ticket-advice-create"]')["href"]
      expect(link).to include(CGI.escape(advice))
      expect(link).to include("source_ticket_id=#{ticket.id}")
      expect(link).to include("project_id=#{project.id}")
    end

    it "legge anche i consigli del resoconto corrente" do
      ticket = create(:ticket, organization: organization, project: project)
      Ticketing::RecordReport.call(ticket: ticket, author: member,
                                   body: "**Fatto:** fatto.\n\n**Consigli:**\n- #{advice}")
      sign_in(member)
      get member_ticket_path(ticket)

      expect(html.css('[data-test="ticket-advice-line"]').length).to eq(1)
    end

    # Lo stesso consiglio scritto in tutti e due i campi è UN lavoro solo: due link che aprono lo
    # stesso ticket sarebbero un invito a crearne due.
    it "non ripete un consiglio presente in entrambi i campi" do
      ticket = create(:ticket, organization: organization, project: project, technical_analysis: analysis)
      Ticketing::RecordReport.call(ticket: ticket, author: member,
                                   body: "**Fatto:** fatto.\n\n**Consigli:**\n- #{advice}")
      sign_in(member)
      get member_ticket_path(ticket)

      expect(html.css('[data-test="ticket-advice-line"]').length).to eq(1)
    end

    it "non mostra il riquadro quando non ci sono consigli" do
      ticket = create(:ticket, organization: organization, project: project, technical_analysis: "**Approccio:** solo questo.")
      sign_in(member)
      get member_ticket_path(ticket)

      expect(html.at_css('[data-test="ticket-advice"]')).to be_nil
    end
  end

  describe "il form precompilato" do
    it "arriva con titolo, descrizione e ticket d'origine già dentro" do
      ticket = create(:ticket, organization: organization, project: project, technical_analysis: analysis)
      sign_in(member)
      get new_member_ticket_path(project_id: project.id, title: advice, description: advice, source_ticket_id: ticket.id)

      expect(html.at_css("#title")["value"]).to eq(advice)
      expect(html.at_css("#description").text).to eq(advice)
      expect(html.at_css('input[name="source_ticket_id"]')["value"]).to eq(ticket.id)
    end

    it "senza ticket d'origine non porta il campo nascosto" do
      sign_in(member)
      get new_member_ticket_path(project_id: project.id)

      expect(html.at_css('input[name="source_ticket_id"]')).to be_nil
    end
  end

  describe "il collegamento dopo la creazione" do
    let(:source) { create(:ticket, organization: organization, project: project, technical_analysis: analysis) }

    def create_ticket(source_ticket_id:)
      post member_tickets_path, params: {
        project_id: project.id, title: "Un titolo nuovo e diverso da tutti gli altri",
        description: "Una descrizione qualsiasi.", kind: "task", status_id: status.id,
        priority_id: priority.id, source_ticket_id: source_ticket_id
      }
    end

    it "lega il ticket nuovo a quello che ha suggerito il lavoro" do
      sign_in(member)
      expect { create_ticket(source_ticket_id: source.id) }.to change(Connections::TicketLink, :count).by(1)

      link = Connections::TicketLink.last
      expect(link.related_id).to eq(source.id)
      expect(link.kind).to eq("related")
    end

    # Il collegamento si vede da entrambe le parti: lo scope `involving` è simmetrico, e chi apre il
    # ticket vecchio deve sapere che quel consiglio è diventato lavoro.
    it "si vede da entrambe le schede" do
      sign_in(member)
      create_ticket(source_ticket_id: source.id)
      created = Ticketing::Ticket.order(:created_at).last

      expect(Connections::TicketLink.involving(source)).to be_present
      expect(Connections::TicketLink.involving(created)).to be_present
    end

    # Un'origine irraggiungibile non deve costare il ticket appena scritto: si crea lo stesso, senza
    # collegamento. È la differenza fra un collegamento mancato e un form da ricompilare.
    it "crea il ticket anche se l'origine è di un'altra organizzazione" do
      other = create(:ticket, organization: create(:organization))
      sign_in(member)

      expect { create_ticket(source_ticket_id: other.id) }.to change(Ticketing::Ticket, :count).by(1)
      expect(Connections::TicketLink.count).to eq(0)
    end

    it "ignora un'origine inesistente" do
      sign_in(member)

      expect { create_ticket(source_ticket_id: SecureRandom.uuid) }.to change(Ticketing::Ticket, :count).by(1)
      expect(Connections::TicketLink.count).to eq(0)
    end

    it "senza origine non crea nessun collegamento" do
      sign_in(member)

      expect { create_ticket(source_ticket_id: nil) }.not_to change(Connections::TicketLink, :count)
    end
  end
end
