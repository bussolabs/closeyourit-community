# frozen_string_literal: true

require "rails_helper"

# Le due domande che i tre passaggi della revisione (accetta, scarta, segna come archiviata) si fanno
# ogni volta. Vivono qui perché una risposta diversa fra i tre sarebbe un buco, e per la stessa ragione
# hanno una prova propria: gli spec dei tre passaggi verificano il loro esito, non il contratto
# condiviso — codici, stato HTTP e polarità dei predicati — che è ciò che li tiene allineati.
RSpec.describe Knowledge::Pages::ReviewGuards do
  # Passaggio finto: espone le guardie senza portarsi dietro la logica di nessuno dei tre veri.
  let(:passaggio) do
    Class.new do
      include Knowledge::Pages::ReviewGuards

      def initialize(page:, actor:)
        @page = page
        @actor = actor
      end

      public :manageable?, :human_actor?, :machine_decision, :forbidden, :wrong_status
    end
  end

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
  end
  let(:page) { create(:knowledge_page, :in_review, organization:, project:) }

  def guardie(actor:, target: page) = passaggio.new(page: target, actor:)

  describe "chi agisce è una persona" do
    it "una persona sì" do
      expect(guardie(actor: owner).human_actor?).to be(true)
    end

    it "un accesso automatico no, anche se ha i permessi per gestire la pagina" do
      macchina = create(:account, :service)
      create(:membership, account: macchina, organization:, role: :owner)

      guard = guardie(actor: macchina)
      expect(guard.human_actor?).to be(false)
      expect(guard.manageable?).to be(true)
    end

    # Fail-closed: non sapere chi agisce non è una ragione per lasciar decidere.
    it "attore assente vale come non umano" do
      expect(guardie(actor: nil).human_actor?).to be(false)
    end
  end

  describe "chi agisce può gestire la pagina" do
    it "chi ha accesso pieno all'organizzazione sì" do
      expect(guardie(actor: owner).manageable?).to be(true)
    end

    it "chi non vede il progetto della pagina no" do
      estraneo = create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }

      expect(guardie(actor: estraneo).manageable?).to be(false)
    end

    it "chi sta in un'altra organizzazione no" do
      altrove = create(:account).tap do |account|
        create(:membership, account:, organization: create(:organization), role: :owner)
      end

      expect(guardie(actor: altrove).manageable?).to be(false)
    end
  end

  # I tre errori sono il contratto verso i due canali che decidono: la pagina di revisione nel web e
  # `cyi kb approve/reject` dal terminale. Cambiare un codice qui li cambia entrambi in silenzio.
  describe "gli errori che le guardie restituiscono" do
    subject(:guard) { guardie(actor: owner) }

    it "una macchina che decide riceve un divieto suo, distinto dal permesso mancante" do
      result = guard.machine_decision

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-005")
      expect(result.error.status).to eq(:forbidden)
      expect(result.error.message).to eq(I18n.t("member.knowledge.errors.review_machine"))
    end

    it "il permesso mancante ha il proprio codice" do
      result = guard.forbidden

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-004")
      expect(result.error.status).to eq(:forbidden)
      expect(result.error.message).to eq(I18n.t("member.knowledge.errors.review_forbidden"))
    end

    # 422 e non 404: la pagina esiste ed è visibile, è la transizione a non essere ammessa.
    it "una transizione chiesta dallo stato sbagliato dice quale stato mancava" do
      non_in_revisione = guard.wrong_status(:not_in_review)
      non_pubblicata = guard.wrong_status(:not_published)

      expect(non_in_revisione.error.code).to eq("R422-KNOWLEDGE-009")
      expect(non_in_revisione.error.status).to eq(:unprocessable_content)
      expect(non_in_revisione.error.message).to eq(I18n.t("member.knowledge.errors.not_in_review"))
      expect(non_pubblicata.error.message).to eq(I18n.t("member.knowledge.errors.not_published"))
    end
  end

  # La conseguenza che tiene insieme il tutto: le stesse guardie danno lo stesso esito nei passaggi
  # veri. Se un giorno una macchina passasse in uno solo dei due, la coda si svuoterebbe da sola.
  it "accettare e scartare rifiutano una macchina con lo stesso codice" do
    macchina = create(:account, :service)
    create(:membership, account: macchina, organization:, role: :owner)

    approvazione = Knowledge::Pages::Approve.call(page:, actor: macchina)
    rifiuto = Knowledge::Pages::Reject.call(page:, actor: macchina)

    expect(approvazione.error.code).to eq("R403-KNOWLEDGE-005")
    expect(rifiuto.error.code).to eq("R403-KNOWLEDGE-005")
    expect(page.reload).to be_status_in_review
  end
end
