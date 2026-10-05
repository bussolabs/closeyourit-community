# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::TodoLists::Sharings", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:list) { create(:todo_list, account:, organization: org) }

  before { create(:membership, account:, organization: org, role: :member) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def member!
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end

  describe "GET show" do
    it "mostra il form di condivisione → 200" do
      sign_in(account)
      get member_todo_list_sharing_path(list)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("todo-share-form")
    end

    # CYRA-556 — l'elenco dei destinatari proponeva anche le utenze dei programmi, che la pagina non
    # la aprono mai: solo persone, così l'elenco resta quello dei colleghi.
    it "fra i destinatari propone le persone, non le utenze di servizio" do
      create(:account, name: "Collega Vero").tap { |a| create(:membership, account: a, organization: org, role: :member) }
      bot = create(:account, :service, name: "Agente Notturno")
      create(:membership, account: bot, organization: org, role: :member)

      sign_in(account)
      get member_todo_list_sharing_path(list)

      expect(response.body).to include("Collega Vero")
      expect(response.body).not_to include("Agente Notturno")
    end
  end

  describe "PATCH update" do
    it "imposta i destinatari e reindirizza alla lista" do
      sign_in(account)
      m = member!
      patch member_todo_list_sharing_path(list), params: { account_ids: [ m.id ] }
      expect(response).to redirect_to(member_todo_list_path(list))
      expect(list.reload.shared_accounts).to contain_exactly(m)
    end

    it "destinatario non membro → alert, nessuna condivisione" do
      sign_in(account)
      outsider = create(:account)
      patch member_todo_list_sharing_path(list), params: { account_ids: [ outsider.id ] }
      expect(response).to redirect_to(member_todo_list_sharing_path(list))
      expect(list.reload.shares).to be_empty
    end

    # CYRA-556 — fra i destinatari comparivano anche le utenze usate dai programmi, che dal sito non
    # entrano mai: condividere con loro non serviva a niente e allungava l'elenco da leggere.
    it "un'utenza di servizio passata a mano non diventa destinataria" do
      sign_in(account)
      bot = create(:account, :service)
      create(:membership, account: bot, organization: org, role: :member)

      patch member_todo_list_sharing_path(list), params: { account_ids: [ bot.id ] }

      expect(response).to redirect_to(member_todo_list_sharing_path(list))
      expect(list.reload.shares).to be_empty
    end

    it "condivisione su lista altrui → 404 (anti-BOLA)" do
      sign_in(account)
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :member)
      foreign = create(:todo_list, account: owner, organization: org)
      patch member_todo_list_sharing_path(foreign), params: { account_ids: [] }
      expect(response).to have_http_status(:not_found)
    end
  end
end
