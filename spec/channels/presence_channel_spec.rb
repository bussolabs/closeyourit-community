# frozen_string_literal: true

require "rails_helper"

# PresenceChannel (ActionCable::Channel::TestCase via rspec-rails, type: :channel).
# Copre: subscribe popola lo store + broadcasta sul PROPRIO stream (presence_for) + invia lo
# snapshot FILTRATO alla tab; unsubscribe rimuove + ri-broadcasta ai co-viewer rimasti; heartbeat
# tiene vivo senza storm (diffing per-viewer); reject senza organizzazione; isolamento tenant.
#
# Identità via stub_connection (in produzione arrivano da ApplicationCable::Connection, già
# testata a parte). Lo store usa un MemoryStore reale (in test Rails.cache è :null_store).
RSpec.describe PresenceChannel, type: :channel do
  include_context "realtime presence cache"

  let(:organization) { create(:organization) }
  let(:account) { create(:account, name: "Bob") }
  let!(:membership) { create(:membership, account: account, organization: organization) }
  let(:own_stream) { Realtime::Streams.presence_for(organization, account) }

  describe "#subscribed" do
    before { stub_connection(live_account: account, current_account: account, current_organization: organization) }

    it "conferma la sottoscrizione" do
      subscribe
      expect(subscription).to be_confirmed
    end

    it "registra l'appearance nello store (l'account diventa online)" do
      subscribe
      expect(Realtime::Presence.online(organization).to_a).to include(account)
    end

    it "broadcasta sul PROPRIO stream (replace #presence_list col proprio avatar)" do
      # Alone, the viewer reads "only you" instead of their own initials (CYRA-898).
      expect { subscribe }.to have_broadcasted_to(own_stream)
        .with(a_string_including("presence-only-you"))
    end

    it "invia lo snapshot SOLO a questa tab (transmit con turbo-stream su #presence_list)" do
      subscribe
      snapshot = transmissions.find { |t| t["type"] == "snapshot" }
      expect(snapshot).to be_present
      expect(snapshot["stream"]).to include("presence_list")
    end

    it "lo snapshot è FILTRATO: non mostra un online con cui non si condivide nulla" do
      stranger = create(:account, name: "Zoe")
      create(:membership, account: stranger, organization: organization)
      Realtime::Presence.add(organization, stranger)

      subscribe
      snapshot = transmissions.find { |t| t["type"] == "snapshot" }
      expect(snapshot["stream"]).to include("presence-only-you")
      expect(snapshot["stream"]).not_to include("presence-avatar-#{stranger.id}")
    end

    it "non broadcasta sullo stream presence di un'ALTRA organizzazione (isolamento tenant)" do
      other_org = create(:organization)
      other_viewer = create(:account, name: "Zoe")
      create(:membership, account: other_viewer, organization: other_org)
      expect { subscribe }.not_to have_broadcasted_to(Realtime::Streams.presence_for(other_org, other_viewer))
    end
  end

  describe "#subscribed — senza organizzazione" do
    before { stub_connection(live_account: account, current_account: account, current_organization: nil) }

    it "RIFIUTA la sottoscrizione" do
      subscribe
      expect(subscription).to be_rejected
    end

    it "non popola lo store né broadcasta" do
      expect { subscribe }.not_to have_broadcasted_to(own_stream)
      expect(Realtime::Presence.online(organization)).to be_empty
    end
  end

  describe "#unsubscribed" do
    let(:peer) { create(:account, name: "Alice") }

    before do
      # Alice condivide un progetto con Bob ed è già online: quando Bob esce, il suo stream si aggiorna.
      project = create(:project, organization: organization)
      create(:project_membership, account: account, project: project)
      create(:project_membership, account: peer,    project: project)
      Realtime::Presence.add(organization, peer)
      stub_connection(live_account: account, current_account: account, current_organization: organization)
      subscribe
    end

    it "rimuove l'appearance e ri-broadcasta ai co-viewer rimasti" do
      expect(Realtime::Presence.online(organization).to_a).to include(account)

      expect { unsubscribe }.to have_broadcasted_to(Realtime::Streams.presence_for(organization, peer))
      expect(Realtime::Presence.online(organization).to_a).not_to include(account)
    end
  end

  describe "#heartbeat" do
    before { stub_connection(live_account: account, current_account: account, current_organization: organization) }

    it "tiene l'account online senza ri-broadcastare se il suo insieme non cambia (diffing)" do
      subscribe
      expect { perform("heartbeat") }.not_to have_broadcasted_to(own_stream)
      expect(Realtime::Presence.online(organization).to_a).to include(account)
    end

    it "senza organizzazione corrente → no-op (guard, nessun broadcast)" do
      subscribe
      allow(subscription).to receive(:current_organization).and_return(nil)
      expect { perform("heartbeat") }.not_to have_broadcasted_to(own_stream)
    end
  end
end
