# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::MessageReference, type: :model do
  it "la factory è valida (tag di un progetto)" do
    expect(build(:chat_message_reference)).to be_valid
  end

  describe "tipo taggabile" do
    it "rifiuta un tipo non in whitelist" do
      reference = build(:chat_message_reference)
      reference.referable = create(:account)
      expect(reference).to be_invalid
      expect(reference.errors[:referable_type]).to be_present
    end
  end

  describe "unicità" do
    it "non tagga due volte la stessa risorsa nello stesso messaggio" do
      first = create(:chat_message_reference)
      dup = build(:chat_message_reference, message: first.message, referable: first.referable,
                  organization: first.organization)
      expect(dup).to be_invalid
    end
  end

  describe "integrità tenant (referable stessa org)" do
    it "rifiuta un progetto di un'altra org" do
      message = create(:chat_message)
      other_project = create(:project, organization: create(:organization))
      reference = build(:chat_message_reference, message: message, referable: other_project,
                        organization: message.organization)
      expect(reference).to be_invalid
      expect(reference.errors[:referable]).to be_present
    end

    it "accetta un ticket della stessa org (derivazione via project)" do
      message = create(:chat_message)
      ticket = create(:ticket, organization: message.organization)
      reference = build(:chat_message_reference, message: message, referable: ticket,
                        organization: message.organization)
      expect(reference).to be_valid
    end

    it "rifiuta un error group di un'altra org" do
      message = create(:chat_message)
      foreign_group = create(:error_group, project: create(:project, organization: create(:organization)))
      reference = build(:chat_message_reference, message: message, referable: foreign_group,
                        organization: message.organization)
      expect(reference).to be_invalid
    end

    it "accetta un metric group della stessa org" do
      message = create(:chat_message)
      metric_group = create(:metric_group, project: create(:project, organization: message.organization))
      reference = build(:chat_message_reference, message: message, referable: metric_group,
                        organization: message.organization)
      expect(reference).to be_valid
    end

    it "salta il controllo tenant se organization_id è assente (guard)" do
      reference = described_class.new(referable: create(:project))
      reference.valid? # non deve sollevare: referable_in_organization esce presto (org blank)
      expect(reference.errors[:referable]).to be_empty
    end

    it "rifiuta un'organization diversa da quella del proprio message" do
      message = create(:chat_message)
      other_org = create(:organization)
      project = create(:project, organization: other_org)
      reference = build(:chat_message_reference, message: message, referable: project,
                        organization: other_org)
      expect(reference).to be_invalid
      expect(reference.errors[:organization]).to be_present
    end

    it "accetta un log entry della stessa org e rifiuta quello di un'altra" do
      message = create(:chat_message)
      same = create(:log_entry, project: create(:project, organization: message.organization))
      foreign = create(:log_entry, project: create(:project, organization: create(:organization)))

      expect(build(:chat_message_reference, message: message, referable: same,
                   organization: message.organization)).to be_valid
      expect(build(:chat_message_reference, message: message, referable: foreign,
                   organization: message.organization)).to be_invalid
    end

    it "accetta un uptime monitor della stessa org e rifiuta quello di un'altra" do
      message = create(:chat_message)
      same = create(:uptime_monitor, project: create(:project, organization: message.organization))
      foreign = create(:uptime_monitor, project: create(:project, organization: create(:organization)))

      expect(build(:chat_message_reference, message: message, referable: same,
                   organization: message.organization)).to be_valid
      expect(build(:chat_message_reference, message: message, referable: foreign,
                   organization: message.organization)).to be_invalid
    end
  end
end
