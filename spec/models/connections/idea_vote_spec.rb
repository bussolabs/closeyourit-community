# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::IdeaVote, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project) }
  let(:account) { create(:account) }

  it "è valido quando l'account è membro dell'org dell'idea" do
    create(:membership, account: account, organization: org)
    expect(described_class.new(idea: idea, account: account)).to be_valid
  end

  it "rifiuta un account non membro dell'org dell'idea (integrità tenant)" do
    vote = described_class.new(idea: idea, account: account)
    expect(vote).not_to be_valid
    expect(vote.errors[:account]).to be_present
  end

  it "rifiuta lo stesso account due volte sulla stessa idea (1 voto/account)" do
    create(:membership, account: account, organization: org)
    described_class.create!(idea: idea, account: account)
    dup = described_class.new(idea: idea, account: account)

    expect(dup).not_to be_valid
    expect(dup.errors[:account_id]).to be_present
  end

  it "aggiorna votes_count dell'idea (counter_cache) al voto e alla rimozione" do
    create(:membership, account: account, organization: org)
    vote = described_class.create!(idea: idea, account: account)
    expect(idea.reload.votes_count).to eq(1)

    vote.destroy
    expect(idea.reload.votes_count).to eq(0)
  end

  describe "validatore di integrità tenant nil-safe (nessun crash sui bordi)" do
    it "account assente → esce presto senza eccezioni" do
      vote = described_class.new(idea: idea, account: nil)
      expect { vote.valid? }.not_to raise_error
    end

    it "idea assente → esce presto senza eccezioni" do
      vote = described_class.new(idea: nil, account: account)
      expect { vote.valid? }.not_to raise_error
    end

    it "idea senza progetto (org non risolvibile) → esce presto senza eccezioni" do
      vote = described_class.new(idea: Ideas::Idea.new, account: account)
      expect { vote.valid? }.not_to raise_error
    end
  end
end
