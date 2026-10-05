# frozen_string_literal: true

require "rails_helper"

# Le guardie condivise dai tre service che decidono su una richiesta di modifica ai segreti. Hanno una
# prova propria perché il contratto è ciò che li tiene allineati: `requester?` è lo STESSO predicato
# usato con polarità opposta da Approve/Reject (chi decide non è chi ha chiesto) e da Cancel (solo chi
# ha chiesto ritira). Invertirlo per sbaglio da una parte sola non romperebbe nessuna prova dell'altra.
RSpec.describe Secrets::ChangeRequests::DecisionGuard do
  let(:decisione) do
    Class.new do
      include Secrets::ChangeRequests::DecisionGuard

      def initialize(change_request:, actor:)
        @change_request = change_request
        @actor = actor
      end

      public :stale?, :stale, :requester?, :self_decision, :human_actor?, :machine_decision
    end
  end

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:richiedente) { create(:account) }
  let(:change_request) { create(:secret_change_request, project:, organization:, requested_by: richiedente) }

  def guardie(actor:, request: change_request) = decisione.new(change_request: request, actor:)

  describe "la richiesta è ancora da decidere" do
    it "una richiesta in attesa sì" do
      expect(guardie(actor: richiedente).stale?).to be(false)
    end

    it "una già applicata, rifiutata o ritirata no" do
      %i[applied rejected cancelled].each do |stato|
        change_request.update!(status: stato)

        expect(guardie(actor: richiedente).stale?).to be(true)
      end
    end

    # Conflitto e non silenzio: decidere due volte deve dirlo, altrimenti chi ha cliccato crede di
    # aver deciso qualcosa che qualcun altro aveva già deciso diversamente.
    it "il rifiuto è un conflitto, non un'operazione andata a vuoto" do
      result = guardie(actor: richiedente).stale

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
      expect(result.error.status).to eq(:conflict)
    end
  end

  describe "chi decide non è chi ha chiesto" do
    it "riconosce il richiedente" do
      expect(guardie(actor: richiedente).requester?).to be(true)
    end

    it "e chiunque altro no" do
      expect(guardie(actor: create(:account)).requester?).to be(false)
    end

    it "decidere la propria richiesta è vietato, con codice e stato suoi" do
      result = guardie(actor: richiedente).self_decision

      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHANGEREQUEST-001")
      expect(result.error.status).to eq(:forbidden)
    end
  end

  describe "chi decide è una persona" do
    it "una persona sì" do
      expect(guardie(actor: richiedente).human_actor?).to be(true)
    end

    it "un accesso automatico no" do
      expect(guardie(actor: create(:account, :service)).human_actor?).to be(false)
    end

    it "attore assente vale come non umano" do
      expect(guardie(actor: nil).human_actor?).to be(false)
    end

    it "il divieto per le macchine è distinto da quello del 4-eyes" do
      result = guardie(actor: richiedente).machine_decision

      expect(result.error.code).to eq("R403-CHANGEREQUEST-003")
      expect(result.error.status).to eq(:forbidden)
      expect(result.error.code).not_to eq("R403-CHANGEREQUEST-001")
    end
  end

  # La conseguenza che tiene insieme i tre service: la stessa domanda, usata con polarità opposta.
  describe "la polarità nei tre passaggi veri" do
    let(:decisore) do
      create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
    end

    it "approvare la propria richiesta è vietato, approvarla da un altro no" do
      expect(Secrets::ChangeRequests::Approve.call(change_request:, actor: richiedente).error.code)
        .to eq("R403-CHANGEREQUEST-001")
    end

    it "rifiutare la propria richiesta è vietato" do
      expect(Secrets::ChangeRequests::Reject.call(change_request:, actor: richiedente, reason: "no").error.code)
        .to eq("R403-CHANGEREQUEST-001")
    end

    it "ritirare la propria richiesta si può; ritirare quella di un altro no" do
      expect(Secrets::ChangeRequests::Cancel.call(change_request:, actor: richiedente)).to be_ok

      altra = create(:secret_change_request, project:, organization:, requested_by: richiedente)
      result = Secrets::ChangeRequests::Cancel.call(change_request: altra, actor: decisore)

      expect(result.error.code).to eq("R403-CHANGEREQUEST-002")
      expect(altra.reload).to be_pending
    end

    # Una macchina non decide, ma deve poter rinunciare a ciò che ha chiesto: altrimenti la richiesta
    # resta in attesa finché un umano non la rifiuta.
    it "una macchina non approva né rifiuta, ma può ritirare la propria richiesta" do
      macchina = create(:account, :service)
      sua = create(:secret_change_request, project:, organization:, requested_by: macchina)

      expect(Secrets::ChangeRequests::Approve.call(change_request: sua, actor: macchina).error.code)
        .to eq("R403-CHANGEREQUEST-003")
      expect(Secrets::ChangeRequests::Cancel.call(change_request: sua, actor: macchina)).to be_ok
    end
  end
end
