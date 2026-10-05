# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime della presenza (Presence::Broadcast), ora PER-VIEWER:
#  - ogni viewer online riceve sul PROPRIO stream (presence_for) solo gli online che può vedere;
#  - member vede sé + owner + co-membri (chi condivide progetto/gruppo/team); owner/god vedono tutti;
#  - diffing per-viewer: ri-emette al singolo viewer SOLO quando il SUO insieme visibile cambia;
#  - isolamento tenant (stream org+account-prefissato).
# (have_broadcasted_to su stream String legge il broadcast Turbo grezzo, come gli altri broadcast.)
RSpec.describe Presence::Broadcast, type: :service do
  include_context "realtime presence cache"

  let(:organization) { create(:organization) }
  let(:account) { create(:account, name: "Bob") }
  let!(:membership) { create(:membership, account: account, organization: organization) }

  def call = described_class.call(organization: organization)
  def presence_for(viewer) = Realtime::Streams.presence_for(organization, viewer)
  def member(name)
    a = create(:account, name: name)
    create(:membership, account: a, organization: organization)
    a
  end

  describe "un solo account online (member senza assegnazioni)" do
    before { Realtime::Presence.add(organization, account) }

    it "ritorna Result.ok con gli account online" do
      result = call
      expect(result).to be_ok
      expect(result.value.to_a).to contain_exactly(account)
    end

    it "broadcasta sul SUO stream la lista con sé stesso (self sempre visibile)" do
      # Alone, the viewer reads "only you" instead of their own initials (CYRA-898).
      expect { call }.to have_broadcasted_to(presence_for(account))
        .with(a_string_including("presence_list").and(a_string_including("presence-only-you")))
    end
  end

  describe "filtro per contesto condiviso" do
    let(:peer) { member("Peer") }

    before do
      Realtime::Presence.add(organization, account)
      Realtime::Presence.add(organization, peer)
    end

    context "quando condividono un progetto" do
      before do
        project = create(:project, organization: organization)
        create(:project_membership, account: account, project: project)
        create(:project_membership, account: peer,    project: project)
      end

      it "il viewer riceve il peer sul proprio stream" do
        expect { call }.to have_broadcasted_to(presence_for(account))
          .with(a_string_including("presence-avatar-#{peer.id}"))
      end
    end

    context "quando NON condividono nulla" do
      it "il viewer NON riceve il peer sul proprio stream" do
        expect { call }.not_to have_broadcasted_to(presence_for(account))
          .with(a_string_including("presence-avatar-#{peer.id}"))
      end

      it "il peer riceve comunque sé stesso sul proprio stream" do
        expect { call }.to have_broadcasted_to(presence_for(peer))
          .with(a_string_including("presence-only-you"))
      end
    end
  end

  describe "owner" do
    let(:boss) { create(:account, name: "Boss").tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }

    before do
      Realtime::Presence.add(organization, account) # member senza assegnazioni
      Realtime::Presence.add(organization, boss)
    end

    it "l'owner (unscoped) vede tutti gli online sul proprio stream" do
      expect { call }.to have_broadcasted_to(presence_for(boss))
        .with(a_string_including("presence-avatar-#{account.id}"))
    end

    it "l'owner è SEMPRE visibile al member sul suo stream" do
      expect { call }.to have_broadcasted_to(presence_for(account))
        .with(a_string_including("presence-avatar-#{boss.id}"))
    end
  end

  describe "diffing per-viewer (fingerprint)" do
    before { Realtime::Presence.add(organization, account) }

    it "NON ri-broadcasta al viewer se il SUO insieme visibile non cambia" do
      expect { call; call }.to have_broadcasted_to(presence_for(account)).once
    end

    it "l'ingresso di un estraneo NON tocca il viewer (insieme invariato) ma raggiunge l'estraneo" do
      call # Bob vede {Bob}
      ann = member("Ann") # nessun contesto con Bob
      Realtime::Presence.add(organization, ann)

      expect { call }.not_to have_broadcasted_to(presence_for(account))
    end

    it "l'ingresso di un estraneo broadcasta sullo stream DELL'estraneo (sé stesso)" do
      call
      ann = member("Ann")
      Realtime::Presence.add(organization, ann)

      expect { call }.to have_broadcasted_to(presence_for(ann))
        .with(a_string_including("presence-only-you"))
    end
  end

  describe "insieme vuoto" do
    it "non broadcasta a nessuno (nessun viewer online)" do
      expect { call }.not_to have_broadcasted_to(presence_for(account))
    end
  end

  describe "isolamento tenant" do
    before { Realtime::Presence.add(organization, account) }

    it "non broadcasta sullo stream presence di un viewer di un'ALTRA organizzazione" do
      other_org = create(:organization)
      other_viewer = create(:account, name: "Zoe")
      create(:membership, account: other_viewer, organization: other_org)
      expect { call }.not_to have_broadcasted_to(Realtime::Streams.presence_for(other_org, other_viewer))
    end
  end
end
