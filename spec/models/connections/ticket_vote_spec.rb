# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::TicketVote, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }
  let(:account) { create(:account) }

  it "è valida quando l'account è membro dell'org del ticket" do
    create(:membership, account: account, organization: org)
    expect(described_class.new(ticket: ticket, account: account)).to be_valid
  end

  it "rifiuta un account non membro dell'org del ticket (integrità tenant)" do
    vote = described_class.new(ticket: ticket, account: account)
    expect(vote).not_to be_valid
    expect(vote.errors[:account]).to be_present
  end

  it "rifiuta lo stesso account due volte sullo stesso ticket (1 voto/account)" do
    create(:membership, account: account, organization: org)
    described_class.create!(ticket: ticket, account: account)
    dup = described_class.new(ticket: ticket, account: account)

    expect(dup).not_to be_valid
    expect(dup.errors[:account_id]).to be_present
  end

  it "aggiorna votes_count del ticket (counter_cache) al voto e alla rimozione" do
    create(:membership, account: account, organization: org)
    vote = described_class.create!(ticket: ticket, account: account)
    expect(ticket.reload.votes_count).to eq(1)

    vote.destroy
    expect(ticket.reload.votes_count).to eq(0)
  end

  describe "validatore di integrità tenant nil-safe (nessun crash sui bordi)" do
    it "account assente → esce presto senza eccezioni" do
      vote = described_class.new(ticket: ticket, account: nil)
      expect { vote.valid? }.not_to raise_error
    end

    it "ticket assente → esce presto senza eccezioni" do
      vote = described_class.new(ticket: nil, account: account)
      expect { vote.valid? }.not_to raise_error
    end

    it "ticket senza progetto (org non risolvibile) → esce presto senza eccezioni" do
      vote = described_class.new(ticket: Ticketing::Ticket.new, account: account)
      expect { vote.valid? }.not_to raise_error
    end
  end
end
