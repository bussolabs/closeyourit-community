# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::NextDecision do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:project) { create(:project, organization:) }

  before { organization.update_column(:cto_id, account.id) }

  let(:visible_projects) { Projects::Project.where(id: project.id) }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: visible_projects.select(:id)) }

  def prossima(skipped: [])
    described_class.call(account:, organization:, visible_projects:, visible_tickets:, skipped:)
  end

  def crea_ticket(**attributes)
    create(:ticket, organization:, project:, **attributes)
  end

  # Un piano da approvare: la famiglia più semplice della coda.
  def crea_piano(planned_at: Time.current)
    create(:agent_workflow, ticket: crea_ticket, planned_at:)
  end

  describe "quando non c'è niente da decidere" do
    it "non torna nessuna card e dice che la coda è vuota" do
      risultato = prossima

      expect(risultato.card).to be_nil
      expect(risultato.card?).to be(false)
      expect(risultato.total).to be_zero
      expect(risultato.all_hidden?).to be(false)
    end
  end

  describe "quale decisione viene messa davanti" do
    it "sceglie la più vecchia" do
      vecchio = crea_piano(planned_at: 3.days.ago)
      crea_piano(planned_at: 1.hour.ago)

      expect(prossima.card.key).to eq("agent_plan:#{vecchio.id}")
    end

    it "conta tutte quelle in coda, non solo quella mostrata" do
      3.times { |n| crea_piano(planned_at: (n + 1).days.ago) }

      expect(prossima.total).to eq(3)
    end
  end

  describe "le decisioni rimandate a domani" do
    it "salta quella rimandata e mostra la successiva" do
      rimandato = crea_piano(planned_at: 3.days.ago)
      successivo = crea_piano(planned_at: 2.days.ago)
      create(:home_deferral, account:, organization:, card_key: "agent_plan:#{rimandato.id}")

      risultato = prossima

      expect(risultato.card.key).to eq("agent_plan:#{successivo.id}")
      expect(risultato.deferred_count).to eq(1)
    end

    it "continua a contarla fra quelle in coda: il totale dice quante ce ne sono, non quante ne vedo" do
      rimandato = crea_piano(planned_at: 3.days.ago)
      create(:home_deferral, account:, organization:, card_key: "agent_plan:#{rimandato.id}")

      expect(prossima.total).to eq(1)
    end

    it "torna a mostrarla quando il rimando è scaduto" do
      piano = crea_piano(planned_at: 3.days.ago)
      create(:home_deferral, :expired, account:, organization:, card_key: "agent_plan:#{piano.id}")

      expect(prossima.card.key).to eq("agent_plan:#{piano.id}")
    end

    it "non risente del rimando di un'altra persona sulla stessa decisione" do
      piano = crea_piano(planned_at: 3.days.ago)
      create(:home_deferral, account: create(:account), card_key: "agent_plan:#{piano.id}")

      expect(prossima.card.key).to eq("agent_plan:#{piano.id}")
    end

    it "dice che è tutto nascosto quando la coda non è vuota ma non resta niente da mostrare" do
      piano = crea_piano(planned_at: 3.days.ago)
      create(:home_deferral, account:, organization:, card_key: "agent_plan:#{piano.id}")

      risultato = prossima

      expect(risultato.card).to be_nil
      expect(risultato.all_hidden?).to be(true)
    end
  end

  describe "le decisioni messe da parte in questa sessione" do
    it "salta quelle saltate e le conta a parte" do
      saltato = crea_piano(planned_at: 3.days.ago)
      successivo = crea_piano(planned_at: 2.days.ago)

      risultato = prossima(skipped: [ "agent_plan:#{saltato.id}" ])

      expect(risultato.card.key).to eq("agent_plan:#{successivo.id}")
      expect(risultato.skipped_count).to eq(1)
    end
  end

  describe "quando la decisione sparisce sotto le mani" do
    it "passa alla successiva invece di rendere una card vuota" do
      sparito = crea_piano(planned_at: 3.days.ago)
      successivo = crea_piano(planned_at: 2.days.ago)

      # Fra il calcolo della coda e la risoluzione, una collega ha deciso la prima.
      allow(Home::Approvals::Detail).to receive(:call).and_wrap_original do |original, **kwargs|
        kwargs[:key] == "agent_plan:#{sparito.id}" ? nil : original.call(**kwargs)
      end

      expect(prossima.card.key).to eq("agent_plan:#{successivo.id}")
    end

    it "si arrende senza esplodere se non ne risolve nessuna" do
      2.times { |n| crea_piano(planned_at: (n + 1).days.ago) }
      allow(Home::Approvals::Detail).to receive(:call).and_return(nil)

      risultato = prossima

      expect(risultato.card).to be_nil
      expect(risultato.total).to eq(2)
    end
  end

  describe "isolamento fra organizzazioni" do
    it "non mostra una decisione di un progetto che non mi compete" do
      altro_progetto = create(:project, organization: create(:organization))
      create(:agent_workflow,
             ticket: create(:ticket, organization: altro_progetto.organization, project: altro_progetto),
             planned_at: 3.days.ago)

      risultato = prossima

      expect(risultato.card).to be_nil
      expect(risultato.total).to be_zero
    end
  end
end
