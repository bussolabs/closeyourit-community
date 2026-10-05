# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Subscription, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }
  let(:account) { create(:account) }

  it "è valida quando l'account è membro dell'org del ticket" do
    create(:membership, account: account, organization: org)
    expect(described_class.new(ticket: ticket, account: account, organization: org)).to be_valid
  end

  it "rifiuta un account non membro dell'org del ticket (integrità tenant)" do
    subscription = described_class.new(ticket: ticket, account: account, organization: org)
    expect(subscription).not_to be_valid
    expect(subscription.errors[:account]).to be_present
  end

  it "rifiuta un'org che non combacia con quella del ticket (denormalizzazione coerente)" do
    create(:membership, account: account, organization: org)
    subscription = described_class.new(ticket: ticket, account: account, organization: create(:organization))
    expect(subscription).not_to be_valid
    expect(subscription.errors[:organization]).to be_present
  end

  it "rifiuta lo stesso account due volte sullo stesso ticket (1 iscrizione/account)" do
    create(:membership, account: account, organization: org)
    described_class.create!(ticket: ticket, account: account, organization: org)
    dup = described_class.new(ticket: ticket, account: account, organization: org)

    expect(dup).not_to be_valid
    expect(dup.errors[:account_id]).to be_present
  end

  describe ".ensure_for" do
    before { create(:membership, account: account, organization: org) }

    it "crea la sottoscrizione se non esiste, denormalizzando l'org dal ticket" do
      expect { described_class.ensure_for(ticket: ticket, account: account, source: :reporter) }
        .to change(described_class, :count).by(1)

      subscription = described_class.last
      expect(subscription.organization_id).to eq(org.id)
      expect(subscription.source_reporter?).to be(true)
    end

    it "è idempotente: la seconda chiamata non crea un duplicato" do
      described_class.ensure_for(ticket: ticket, account: account, source: :reporter)
      expect { described_class.ensure_for(ticket: ticket, account: account, source: :commenter) }
        .not_to change(described_class, :count)
    end

    it "non declassa la source di una sottoscrizione già esistente" do
      described_class.ensure_for(ticket: ticket, account: account, source: :manual)
      described_class.ensure_for(ticket: ticket, account: account, source: :commenter)

      expect(described_class.find_by(ticket: ticket, account: account).source_manual?).to be(true)
    end

    it "race concorrente (RecordNotUnique) → recupera la sottoscrizione già esistente" do
      existing = described_class.create!(ticket: ticket, account: account, organization: org)
      allow(described_class).to receive(:find_or_create_by).and_raise(ActiveRecord::RecordNotUnique)

      result = described_class.ensure_for(ticket: ticket, account: account, source: :manual)

      expect(result).to eq(existing)
    end
  end

  describe "validatori di integrità tenant nil-safe (nessun crash sui bordi)" do
    it "ticket assente → i validatori escono presto senza eccezioni" do
      subscription = described_class.new(ticket: nil, account: account, organization: org)
      expect { subscription.valid? }.not_to raise_error
      expect(subscription).not_to be_valid # invalida per presenza del ticket
    end

    it "ticket senza progetto (org non risolvibile) → i validatori escono presto senza eccezioni" do
      orphan = Ticketing::Ticket.new
      subscription = described_class.new(ticket: orphan, account: account, organization: org)
      expect { subscription.valid? }.not_to raise_error
    end
  end
end
