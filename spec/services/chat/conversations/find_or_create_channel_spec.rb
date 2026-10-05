# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::Conversations::FindOrCreateChannel do
  let(:org) { create(:organization) }

  describe "canale di progetto" do
    it "lo crea se l'actor vede il progetto, con la riga di stato dell'actor" do
      project = create(:project, organization: org)
      actor = create(:account)
      create(:membership, account: actor, organization: org, role: :member)
      create(:project_membership, account: actor, project: project)

      result = described_class.call(organization: org, contextable: project, actor: actor)
      expect(result).to be_ok
      conversation = result.value
      expect(conversation.kind_project?).to be(true)
      expect(conversation.contextable).to eq(project)
      expect(conversation.participants.where(account_id: actor.id)).to exist
    end

    it "rifiuta se l'actor non vede il progetto (R403-CHAT-006)" do
      project = create(:project, organization: org)
      actor = create(:account)
      create(:membership, account: actor, organization: org, role: :member) # nessun accesso al progetto

      result = described_class.call(organization: org, contextable: project, actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHAT-006")
    end

    it "è idempotente per contesto" do
      project = create(:project, organization: org)
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)

      first = described_class.call(organization: org, contextable: project, actor: owner).value
      second = described_class.call(organization: org, contextable: project, actor: owner).value
      expect(second.id).to eq(first.id)
      expect(Chat::Conversation.where(organization: org, contextable: project).count).to eq(1)
    end
  end

  describe "canale di team" do
    it "lo crea se l'actor appartiene al team" do
      team = create(:team, organization: org)
      actor = create(:account)
      create(:membership, account: actor, organization: org, role: :member)
      create(:team_membership, team: team, account: actor)

      result = described_class.call(organization: org, contextable: team, actor: actor)
      expect(result).to be_ok
      expect(result.value.kind_team?).to be(true)
    end

    it "rifiuta se l'actor non appartiene al team (R403-CHAT-006)" do
      team = create(:team, organization: org)
      actor = create(:account)
      create(:membership, account: actor, organization: org, role: :member)

      result = described_class.call(organization: org, contextable: team, actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHAT-006")
    end
  end

  describe "contesto invalido" do
    it "rifiuta un contextable non progetto/team (R422-CHAT-005)" do
      actor = create(:account)
      create(:membership, account: actor, organization: org, role: :owner)
      result = described_class.call(organization: org, contextable: create(:account), actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHAT-005")
    end
  end

  describe "canale non persistito (path difensivo)" do
    let(:owner) do
      account = create(:account)
      create(:membership, account: account, organization: org, role: :owner)
      account
    end
    let(:project) { create(:project, organization: org) }

    it "ritorna err con dettagli (R422-CHAT-007)" do
      allow(Chat::Conversation).to receive(:find_or_create_by).and_return(Chat::Conversation.new)
      result = described_class.call(organization: org, contextable: project, actor: owner)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHAT-007")
    end

    it "ritorna err anche se il find_or_create è nil (race)" do
      allow(Chat::Conversation).to receive(:find_or_create_by).and_return(nil)
      result = described_class.call(organization: org, contextable: project, actor: owner)
      expect(result).to be_err
    end

    it "sopravvive alla race sull'INSERT concorrente (RecordNotUnique → rilegge)" do
      winner = Chat::Conversation.create!(organization: org, kind: :project, contextable: project)
      allow(Chat::Conversation).to receive(:find_or_create_by)
        .and_raise(ActiveRecord::RecordNotUnique)
      allow(Chat::Conversation).to receive(:find_by).and_return(winner)

      result = described_class.call(organization: org, contextable: project, actor: owner)
      expect(result).to be_ok
      expect(result.value.id).to eq(winner.id)
    end
  end
end
