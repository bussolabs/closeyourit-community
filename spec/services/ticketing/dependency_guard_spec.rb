# frozen_string_literal: true

require "rails_helper"

# Guard condiviso del gate dipendenze (CYRA-81). Choke-point unico: decide se un ticket con
# prerequisiti (blocker) non ancora "done" può entrare in uno status di category in_progress o done.
RSpec.describe Ticketing::DependencyGuard do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org) }
  let(:in_progress) { create(:ticket_status, :in_progress, organization: org) }
  let(:done) { create(:ticket_status, :done, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: open_status) }
  let(:blocker) { create(:ticket, organization: org, project: project, status: open_status, with_agent_workflow: true) }

  def block_with(status)
    create(:ticket_dependency, ticket: ticket, blocker: blocker)
    blocker.update!(status: status)
  end

  describe "category del target non gated (open)" do
    it "permette il movimento verso open anche con un prerequisito aperto" do
      block_with(open_status)
      result = described_class.call(ticket: ticket, target_category: "open")
      expect(result).to be_ok
      expect(result.value).to eq(ticket)
    end
  end

  describe "target gated con prerequisito aperto" do
    before { block_with(open_status) }

    it "verso in_progress → err R422-TICKET-014" do
      result = described_class.call(ticket: ticket, target_category: in_progress.category)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
      expect(result.error.status).to eq(:unprocessable_content)
    end

    it "verso done → err R422-TICKET-014" do
      result = described_class.call(ticket: ticket, target_category: done.category)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
    end

    it "il messaggio è la stringa i18n localizzata (nessuna chiave grezza)" do
      result = described_class.call(ticket: ticket, target_category: "done")
      expect(result.error.message).to eq(
        I18n.t("member.tickets.errors.blocked_by_dependencies", count: 1)
      )
    end
  end

  describe "target gated con tutti i prerequisiti done" do
    it "verso in_progress → ok" do
      block_with(done)
      result = described_class.call(ticket: ticket, target_category: "in_progress")
      expect(result).to be_ok
    end

    it "senza alcuna dipendenza → ok" do
      result = described_class.call(ticket: ticket, target_category: "done")
      expect(result).to be_ok
    end
  end

  describe "dettaglio strutturato dell'errore" do
    it "elenca i prerequisiti aperti (id/code/title) + conteggio totale aperti" do
      block_with(open_status)
      result = described_class.call(ticket: ticket, target_category: "in_progress")

      expect(result.error.details[:open_count]).to eq(1)
      expect(result.error.details[:dependencies]).to eq(
        [ { id: blocker.id, code: blocker.code, title: blocker.title } ]
      )
    end

    it "limita l'elenco e riporta comunque il conteggio totale nel residuo" do
      stub_const("Ticketing::DependencyGuard::LIST_LIMIT", 2)
      3.times do
        other = create(:ticket, organization: org, project: project, status: open_status)
        create(:ticket_dependency, ticket: ticket, blocker: other)
      end

      result = described_class.call(ticket: ticket, target_category: "done")

      expect(result.error.details[:open_count]).to eq(3)
      expect(result.error.details[:dependencies].size).to eq(2)
    end

    it "conta solo i prerequisiti NON done (i done non entrano nell'elenco né nel conteggio)" do
      closed_blocker = create(:ticket, organization: org, project: project, status: done)
      create(:ticket_dependency, ticket: ticket, blocker: closed_blocker)
      block_with(open_status)

      result = described_class.call(ticket: ticket, target_category: "in_progress")

      expect(result.error.details[:open_count]).to eq(1)
      expect(result.error.details[:dependencies].map { |d| d[:id] }).to eq([ blocker.id ])
    end

    it "compone code e title in un'unica query aggregata (blocker cross-project, no query per riga)" do
      block_with(open_status)
      other = create(:ticket, organization: org, project: create(:project, organization: org),
                              status: open_status)
      create(:ticket_dependency, ticket: ticket, blocker: other)

      result = described_class.call(ticket: ticket, target_category: "done")

      codes = result.error.details[:dependencies].map { |d| d[:code] }
      expect(codes).to contain_exactly(blocker.code, other.code)
    end
  end

  # ── CYRA-622 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Il guard impara una seconda domanda. Non la sostituisce: sono due domande diverse per due momenti
  # diversi, e confonderle costa da una parte un giro di rilascio e dall'altra un ticket chiuso su un
  # prerequisito che in produzione non c'è.
  describe "quale domanda si fa al prerequisito" do
    def blocker_unito!
      blocker.agent_workflow.update!(closer_staging_completed_at: 10.minutes.ago,
                                     closer_staging_verified_at: 5.minutes.ago)
    end

    it "`:merged` accetta un prerequisito col codice unito e provato, anche se non è Fatto" do
      block_with(open_status)
      blocker_unito!

      expect(described_class.call(ticket:, target_category: "in_progress", mode: :merged)).to be_ok
    end

    # La regola severa è quella che protegge la chiusura a mano: lì «Fatto» vuol dire rilasciato e
    # provato vivo in produzione, e non si tocca.
    it "il default resta severo: lo stesso prerequisito non basta per chiudere a mano" do
      block_with(open_status)
      blocker_unito!

      result = described_class.call(ticket:, target_category: "done")

      expect(result.error.code).to eq("R422-TICKET-014")
    end

    # Il fatto lo scrive il verificatore dopo aver visto la proposta unita (CYRA-620). La sola
    # dichiarazione della macchina non è una prova, nemmeno per la domanda più mite.
    it "`:merged` non si accontenta della dichiarazione della macchina" do
      block_with(open_status)
      blocker.agent_workflow.update!(closer_staging_completed_at: 10.minutes.ago)

      result = described_class.call(ticket:, target_category: "in_progress", mode: :merged)

      expect(result.error.code).to eq("R422-TICKET-014")
      expect(result.error.details[:dependencies].map { |d| d[:id] }).to eq([ blocker.id ])
    end

    # Un prerequisito Fatto soddisfa entrambe le domande: la più mite non può essere più severa della
    # severa, o metterebbe in fila ticket che la chiusura a mano lascia passare.
    it "`:merged` accetta comunque un prerequisito Fatto" do
      block_with(done)

      expect(described_class.call(ticket:, target_category: "done", mode: :merged)).to be_ok
    end
  end
end
