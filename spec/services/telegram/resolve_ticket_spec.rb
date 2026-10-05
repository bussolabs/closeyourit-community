# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::ResolveTicket do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let(:project) { create(:project, organization: org, key: "DRRA") }
  let!(:ticket) { create(:ticket, :plain_bug, organization: org, project: project) }

  it "risolve un ticket dal code CHIAVE-NUMERO (case-insensitive)" do
    result = described_class.call(account: owner, code: "drra-#{ticket.number}")
    expect(result).to be_ok
    expect(result.value).to eq(ticket)
  end

  it "code malformato → R422-TELEGRAM-007" do
    result = described_class.call(account: owner, code: "non-un-code")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TELEGRAM-007")
  end

  it "numero inesistente → R404-TELEGRAM-005" do
    result = described_class.call(account: owner, code: "DRRA-99999")
    expect(result).to be_err
    expect(result.error.code).to eq("R404-TELEGRAM-005")
  end

  it "ticket di un progetto NON visibile → not found (anti-BOLA)" do
    member = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    result = described_class.call(account: member, code: "DRRA-#{ticket.number}")
    expect(result).to be_err
    expect(result.error.code).to eq("R404-TELEGRAM-005")
  end

  it "ticket di un'altra org non è raggiungibile per code (anti-BOLA)" do
    # La org di owner ha un solo ticket DRRA (numero 1). Nell'altra org creiamo due ticket DRRA così
    # il secondo ha numero 2, che NON esiste nella DRRA di owner → il code estraneo non risolve.
    foreign_org = create(:organization)
    foreign_project = create(:project, organization: foreign_org, key: "DRRA")
    create(:ticket, :plain_bug, organization: foreign_org, project: foreign_project)
    foreign_ticket = create(:ticket, :plain_bug, organization: foreign_org, project: foreign_project)
    expect(foreign_ticket.number).to eq(2)

    result = described_class.call(account: owner, code: "DRRA-#{foreign_ticket.number}")
    expect(result).to be_err
    expect(result.error.code).to eq("R404-TELEGRAM-005")
  end
end
