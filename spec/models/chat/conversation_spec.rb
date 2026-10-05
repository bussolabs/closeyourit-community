# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Conversation, type: :model do
  describe "factory" do
    it "produce un canale di progetto valido" do
      expect(build(:chat_conversation)).to be_valid
    end

    it "produce un DM valido" do
      expect(build(:chat_conversation, :direct)).to be_valid
    end

    it "produce un canale di team valido" do
      expect(build(:chat_conversation, :team)).to be_valid
    end
  end

  describe "validazioni di forma (kind ⇄ contesto)" do
    it "richiede kind" do
      conversation = build(:chat_conversation)
      conversation.kind = nil
      expect(conversation).to be_invalid
    end

    it "un DM richiede direct_key e vieta il contextable" do
      dm = build(:chat_conversation, :direct, direct_key: nil)
      expect(dm).to be_invalid
      expect(dm.errors[:direct_key]).to be_present
    end

    it "un DM con contextable è invalido" do
      org = create(:organization)
      dm = build(:chat_conversation, :direct, organization: org,
                 contextable: create(:project, organization: org))
      expect(dm).to be_invalid
      expect(dm.errors[:contextable]).to be_present
    end

    it "un canale richiede un contextable del tipo giusto" do
      conversation = build(:chat_conversation, contextable: nil)
      expect(conversation).to be_invalid
      expect(conversation.errors[:contextable]).to be_present
    end

    it "un canale di progetto con contextable di team è invalido" do
      org = create(:organization)
      conversation = build(:chat_conversation, organization: org, kind: :project,
                           contextable: create(:team, organization: org))
      expect(conversation).to be_invalid
    end

    it "un canale con direct_key è invalido" do
      conversation = build(:chat_conversation, direct_key: "x")
      expect(conversation).to be_invalid
      expect(conversation.errors[:direct_key]).to be_present
    end
  end

  describe "integrità tenant del contesto" do
    it "rifiuta un contextable di un'altra organizzazione" do
      org = create(:organization)
      other_project = create(:project, organization: create(:organization))
      conversation = build(:chat_conversation, organization: org, kind: :project, contextable: other_project)
      expect(conversation).to be_invalid
      expect(conversation.errors[:contextable]).to be_present
    end
  end

  describe "unicità direct_key" do
    it "vieta due DM con la stessa direct_key nella stessa org" do
      org = create(:organization)
      key = Chat::Conversation.direct_key_for(create(:account), create(:account))
      create(:chat_conversation, :direct, organization: org, direct_key: key)
      dup = build(:chat_conversation, :direct, organization: org, direct_key: key)
      expect(dup).to be_invalid
    end

    it "consente la stessa direct_key in org diverse" do
      key = Chat::Conversation.direct_key_for(create(:account), create(:account))
      create(:chat_conversation, :direct, organization: create(:organization), direct_key: key)
      other = build(:chat_conversation, :direct, organization: create(:organization), direct_key: key)
      expect(other).to be_valid
    end
  end

  describe ".direct_key_for" do
    it "è canonica: indipendente dall'ordine dei due account" do
      a = create(:account)
      b = create(:account)
      expect(described_class.direct_key_for(a, b)).to eq(described_class.direct_key_for(b, a))
    end
  end

  describe ".visible_to" do
    let(:org) { create(:organization) }
    let(:account) { create(:account) }

    before { create(:membership, account: account, organization: org, role: :member) }

    it "include un DM di cui l'account è partecipante ed esclude quello altrui" do
      mine = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: mine, account: account)
      theirs = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: theirs, account: create(:account))

      ids = described_class.visible_to(account: account, organization: org).pluck(:id)
      expect(ids).to include(mine.id)
      expect(ids).not_to include(theirs.id)
    end

    it "include il canale di un progetto visibile, esclude quello di un progetto non visibile" do
      visible_project = create(:project, organization: org)
      create(:project_membership, account: account, project: visible_project)
      hidden_project = create(:project, organization: org)

      visible_channel = create(:chat_conversation, organization: org, kind: :project, contextable: visible_project)
      hidden_channel  = create(:chat_conversation, organization: org, kind: :project, contextable: hidden_project)

      ids = described_class.visible_to(account: account, organization: org).pluck(:id)
      expect(ids).to include(visible_channel.id)
      expect(ids).not_to include(hidden_channel.id)
    end

    it "l'owner vede tutti i canali di progetto dell'org" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      channel = create(:chat_conversation, organization: org, kind: :project,
                       contextable: create(:project, organization: org))

      ids = described_class.visible_to(account: owner, organization: org).pluck(:id)
      expect(ids).to include(channel.id)
    end

    it "include il canale di un team a cui l'account appartiene" do
      team = create(:team, organization: org)
      create(:team_membership, team: team, account: account)
      channel = create(:chat_conversation, organization: org, kind: :team, contextable: team)

      ids = described_class.visible_to(account: account, organization: org).pluck(:id)
      expect(ids).to include(channel.id)
    end
  end

  describe "#accessible_by?" do
    let(:org) { create(:organization) }
    let(:account) { create(:account) }

    before { create(:membership, account: account, organization: org, role: :member) }

    it "un DM è accessibile solo ai partecipanti" do
      dm = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: dm, account: account)
      expect(dm.accessible_by?(account)).to be(true)

      outsider = create(:account)
      create(:membership, account: outsider, organization: org, role: :member)
      expect(dm.accessible_by?(outsider)).to be(false)
    end

    it "un canale è accessibile a chi vede il contesto, non agli altri" do
      seer = create(:account)
      create(:membership, account: seer, organization: org, role: :member)
      project = create(:project, organization: org)
      create(:project_membership, account: seer, project: project)
      channel = create(:chat_conversation, organization: org, kind: :project, contextable: project)

      expect(channel.accessible_by?(seer)).to be(true)
      expect(channel.accessible_by?(account)).to be(false)
    end
  end

  describe "#title_for" do
    let(:org) { create(:organization) }
    let(:viewer) { create(:account, name: "Io") }

    before { create(:membership, account: viewer, organization: org, role: :member) }

    it "per un DM restituisce il nome dell'altro partecipante" do
      other = create(:account, name: "Altro")
      create(:membership, account: other, organization: org, role: :member)
      dm = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: dm, account: viewer)
      create(:chat_participant, conversation: dm, account: other)

      expect(dm.title_for(viewer)).to eq("Altro")
    end

    it "per un canale restituisce il nome del contesto" do
      project = create(:project, organization: org, name: "Storefront")
      channel = create(:chat_conversation, organization: org, kind: :project, contextable: project)
      expect(channel.title_for(viewer)).to eq("Storefront")
    end

    it "per un DM senza l'altro partecipante restituisce nil (nessun crash)" do
      dm = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: dm, account: viewer)
      expect(dm.title_for(viewer)).to be_nil
    end
  end

  describe "#audience" do
    let(:org) { create(:organization) }

    it "per un DM sono i due partecipanti" do
      a = create(:account)
      b = create(:account)
      [ a, b ].each { |x| create(:membership, account: x, organization: org, role: :member) }
      dm = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: dm, account: a)
      create(:chat_participant, conversation: dm, account: b)
      expect(dm.audience).to contain_exactly(a, b)
    end

    it "per un canale di team sono i membri del team" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      team = create(:team, organization: org)
      create(:team_membership, team: team, account: member)
      channel = create(:chat_conversation, organization: org, kind: :team, contextable: team)
      expect(channel.audience).to include(member)
    end

    it "per un canale di progetto sono i destinatari che vedono il progetto" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      project = create(:project, organization: org)
      channel = create(:chat_conversation, organization: org, kind: :project, contextable: project)
      expect(channel.audience).to include(owner)
    end
  end

  describe ".ordered" do
    let(:org) { create(:organization) }

    it "mette prima l'attività recente e in CODA le conversazioni senza messaggi (NULLS LAST)" do
      old = create(:chat_conversation, organization: org, kind: :project,
                   contextable: create(:project, organization: org), last_message_at: 2.days.ago)
      fresh = create(:chat_conversation, organization: org, kind: :project,
                     contextable: create(:project, organization: org), last_message_at: 1.hour.ago)
      silent = create(:chat_conversation, organization: org, kind: :project,
                      contextable: create(:project, organization: org), last_message_at: nil)

      expect(described_class.where(organization: org).ordered.to_a).to eq([ fresh, old, silent ])
    end
  end

  describe "validazioni di forma — kind team (simmetriche al kind project)" do
    let(:org) { create(:organization) }

    it "un canale team con contextable di progetto è invalido" do
      channel = build(:chat_conversation, organization: org, kind: :team,
                      contextable: create(:project, organization: org))
      expect(channel).to be_invalid
      expect(channel.errors[:contextable]).to be_present
    end

    it "rifiuta un team di un'altra organizzazione" do
      foreign_team = create(:team, organization: create(:organization))
      channel = build(:chat_conversation, organization: org, kind: :team, contextable: foreign_team)
      expect(channel).to be_invalid
      expect(channel.errors[:contextable]).to be_present
    end
  end

  describe "dependent alla destroy" do
    let(:org) { create(:organization) }

    it "distrugge partecipanti e messaggi (niente orfani)" do
      account = create(:account)
      create(:membership, account: account, organization: org, role: :member)
      conversation = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: conversation, account: account)
      conversation.messages.create!(body: "resto?", author: account, organization_id: org.id)

      expect { conversation.destroy! }
        .to change(Chat::Participant, :count).by(-1)
        .and change(Chat::Message, :count).by(-1)
    end

    it "la destroy del progetto porta via il suo canale coi messaggi" do
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      project = create(:project, organization: org)
      channel = create(:chat_conversation, organization: org, kind: :project, contextable: project)
      channel.messages.create!(body: "orfano?", author: owner, organization_id: org.id)

      expect { project.destroy! }
        .to change(described_class, :count).by(-1)
        .and change(Chat::Message, :count).by(-1)
    end

    it "la destroy del team porta via il suo canale" do
      team = create(:team, organization: org)
      create(:chat_conversation, organization: org, kind: :team, contextable: team)

      expect { team.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe ".unread_counts_for" do
    let(:org) { create(:organization) }
    let(:me) { create(:account) }
    let(:other) { create(:account) }

    before do
      create(:membership, account: me, organization: org, role: :member)
      create(:membership, account: other, organization: org, role: :member)
    end

    def dm_with_participants
      conversation = create(:chat_conversation, :direct, organization: org)
      create(:chat_participant, conversation: conversation, account: me)
      create(:chat_participant, conversation: conversation, account: other)
      conversation
    end

    it "senza messaggi non letti la conversazione è assente dall'hash (0 implicito)" do
      conversation = dm_with_participants

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ conversation.id ])
      expect(counts[conversation.id]).to be_nil
    end

    it "conta 1 e N messaggi altrui mai letti (last_read_at nil)" do
      one = dm_with_participants
      many = dm_with_participants
      create(:chat_message, conversation: one, author: other)
      create_list(:chat_message, 3, conversation: many, author: other)

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ one.id, many.id ])
      expect(counts[one.id]).to eq(1)
      expect(counts[many.id]).to eq(3)
    end

    it "esclude i messaggi propri" do
      conversation = dm_with_participants
      create(:chat_message, conversation: conversation, author: me)
      create(:chat_message, conversation: conversation, author: other)

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ conversation.id ])
      expect(counts[conversation.id]).to eq(1)
    end

    it "conta i messaggi di un autore cancellato (author nullificato)" do
      conversation = dm_with_participants
      orphan = create(:chat_message, conversation: conversation, author: other)
      orphan.update_columns(author_id: nil)

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ conversation.id ])
      expect(counts[conversation.id]).to eq(1)
    end

    it "esclude i messaggi soft-deleted" do
      conversation = dm_with_participants
      create(:chat_message, conversation: conversation, author: other).soft_delete!

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ conversation.id ])
      expect(counts[conversation.id]).to be_nil
    end

    it "senza riga participant (canale mai aperto) conta tutti i messaggi altrui" do
      project = create(:project, organization: org)
      channel = create(:chat_conversation, organization: org, kind: :project, contextable: project)
      create(:chat_message, conversation: channel, author: other)
      create(:chat_message, conversation: channel, author: me)

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ channel.id ])
      expect(counts[channel.id]).to eq(1)
    end

    it "conta solo i messaggi strettamente dopo last_read_at (confine ±1s)" do
      conversation = dm_with_participants
      read_at = Time.current.change(usec: 0)
      travel_to(read_at - 1.second) { create(:chat_message, conversation: conversation, author: other) }
      travel_to(read_at) { create(:chat_message, conversation: conversation, author: other) }
      travel_to(read_at + 1.second) { create(:chat_message, conversation: conversation, author: other) }
      conversation.participants.find_by(account: me).update!(last_read_at: read_at)

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ conversation.id ])
      expect(counts[conversation.id]).to eq(1)
    end

    it "ignora le conversazioni fuori dalla lista richiesta" do
      inside = dm_with_participants
      outside = dm_with_participants
      create(:chat_message, conversation: inside, author: other)
      create(:chat_message, conversation: outside, author: other)

      counts = described_class.unread_counts_for(account: me, conversation_ids: [ inside.id ])
      expect(counts.keys).to eq([ inside.id ])
    end

    it "con lista vuota risponde con hash vuoto senza query" do
      expect(described_class.unread_counts_for(account: me, conversation_ids: [])).to eq({})
    end
  end
end
