# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatConversationChannel, type: :channel do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }

  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  describe "#subscribed — autorizzazione" do
    it "conferma per un partecipante del DM" do
      me = member_seeing(shared)
      other = member_seeing(shared)
      conversation = Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: me, account_b: other).value

      stub_connection(live_account: me, current_account: me, current_organization: org)
      subscribe(id: conversation.id)
      expect(subscription).to be_confirmed
    end

    it "rifiuta un estraneo al DM" do
      a = member_seeing(shared)
      b = member_seeing(shared)
      conversation = Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: a, account_b: b).value
      outsider = member_seeing(shared)

      stub_connection(live_account: outsider, current_account: outsider, current_organization: org)
      subscribe(id: conversation.id)
      expect(subscription).to be_rejected
    end

    it "conferma per un canale di progetto visibile e rifiuta se non visibile" do
      me = member_seeing(shared)
      channel = Chat::Conversation.create!(organization: org, kind: :project, contextable: shared)

      stub_connection(live_account: me, current_account: me, current_organization: org)
      subscribe(id: channel.id)
      expect(subscription).to be_confirmed

      hidden = Chat::Conversation.create!(organization: org, kind: :project, contextable: create(:project, organization: org))
      stub_connection(live_account: me, current_account: me, current_organization: org)
      subscribe(id: hidden.id)
      expect(subscription).to be_rejected
    end

    it "rifiuta una connessione senza account autenticato" do
      me = member_seeing(shared)
      other = member_seeing(shared)
      conversation = Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: me, account_b: other).value

      stub_connection(live_account: nil, current_account: nil, current_organization: org)
      subscribe(id: conversation.id)
      expect(subscription).to be_rejected
    end

    it "rifiuta una connessione senza organizzazione" do
      me = member_seeing(shared)
      other = member_seeing(shared)
      conversation = Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: me, account_b: other).value

      stub_connection(live_account: me, current_account: me, current_organization: nil)
      subscribe(id: conversation.id)
      expect(subscription).to be_rejected
    end
  end

  describe "azioni" do
    let(:me) { member_seeing(shared) }
    let(:other) { member_seeing(shared) }
    let(:conversation) do
      Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: me, account_b: other).value
    end
    let(:stream) { Realtime::Streams.chat_conversation(conversation) }

    before { stub_connection(live_account: me, current_account: me, current_organization: org) }

    it "typing broadcasta l'indicatore sullo stream della conversazione" do
      subscribe(id: conversation.id)
      expect { perform(:typing) }.to have_broadcasted_to(stream)
    end

    it "mark_read aggiorna last_read_at e broadcasta le ricevute" do
      subscribe(id: conversation.id)
      freeze_time do
        expect { perform(:mark_read) }.to have_broadcasted_to(stream)
        participant = conversation.participants.find_by(account_id: me.id)
        expect(participant.last_read_at).to eq(Time.current)
      end
    end

    # Il canale non passa dal controller che imposta la lingua: senza with_locale le ricevute
    # arrivavano in inglese a chi usa l'italiano, sostituendo il «Letto da» della pagina.
    it "mark_read e typing rendono nella lingua di chi agisce" do
      me.update!(locale: "it")
      Chat::PostMessage.call(conversation: conversation, author: other, params: { body: "ciao" })
      subscribe(id: conversation.id)
      expect { perform(:mark_read) }.to have_broadcasted_to(stream).with(a_string_including("Letto da"))
      expect { perform(:typing) }.to have_broadcasted_to(stream).with(a_string_including("sta scrivendo"))
    end

    it "typing e mark_read con subscription rifiutata non crashano (guard @conversation nil)" do
      outsider = member_seeing(shared)
      stub_connection(live_account: outsider, current_account: outsider, current_organization: org)
      subscribe(id: conversation.id)
      expect(subscription).to be_rejected

      # perform() rifiuta le subscription respinte → si invoca l'action diretta: il guard
      # @conversation.blank? deve uscire pulito, senza broadcast né righe partecipante.
      expect { subscription.typing({}) }.not_to raise_error
      expect { subscription.mark_read({}) }.not_to raise_error
      expect(conversation.participants.where(account_id: outsider.id)).to be_empty
    end
  end

  describe "broadcast del messaggio (Chat::PostMessage)" do
    it "appende la bolla sullo stream della conversazione" do
      me = member_seeing(shared)
      other = member_seeing(shared)
      conversation = Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: me, account_b: other).value
      stream = Realtime::Streams.chat_conversation(conversation)

      expect do
        Chat::PostMessage.call(conversation: conversation, author: me, params: { body: "in diretta" })
      end.to have_broadcasted_to(stream).with(a_string_including("in diretta"))
    end
  end
end
