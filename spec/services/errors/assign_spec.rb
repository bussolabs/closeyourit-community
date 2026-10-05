# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Assign do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project:) }

  def member
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end

  it "assegna un membro dell'org (Result.ok)" do
    assignee = member

    result = described_class.call(group:, assignee_id: assignee.id)

    expect(result).to be_ok
    expect(group.reload.assignee).to eq(assignee)
  end

  it "id vuoto → disassegna" do
    group.update!(assignee: member)

    described_class.call(group:, assignee_id: "")

    expect(group.reload.assignee).to be_nil
  end

  # Anti-BOLA: un account che non è membro dell'org non deve poter diventare assegnatario, nemmeno se
  # il suo id arriva dal client.
  it "account non membro → resta non assegnato" do
    outsider = create(:account)

    result = described_class.call(group:, assignee_id: outsider.id)

    expect(result).to be_ok
    expect(group.reload.assignee).to be_nil
  end

  it "assegnare lo stesso assegnatario è un no-op (nessuna scrittura)" do
    assignee = member
    group.update!(assignee: assignee)

    expect_any_instance_of(Errors::Group).not_to receive(:update!)
    described_class.call(group:, assignee_id: assignee.id)
  end
end
