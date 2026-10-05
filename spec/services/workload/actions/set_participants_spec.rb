# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workload::Actions::SetParticipants, type: :service do
  let(:organization) { create(:organization) }
  let(:team) { create(:team, organization: organization) }
  let(:action) { create(:workload_action, team: team, organization: organization) }
  let(:member_one) { create(:account).tap { |a| create(:team_membership, team: team, account: a) } }
  let(:member_two) { create(:account).tap { |a| create(:team_membership, team: team, account: a) } }
  let(:outsider) { create(:account) }

  it "aggiunge i membri del team" do
    result = described_class.call(action: action, account_ids: [ member_one.id, member_two.id ])

    expect(result).to be_ok
    expect(action.reload.participants).to contain_exactly(member_one, member_two)
  end

  it "scarta gli account non membri del team (anti-BOLA)" do
    described_class.call(action: action, account_ids: [ member_one.id, outsider.id ])

    expect(action.reload.participants).to contain_exactly(member_one)
  end

  it "sostituisce l'insieme rimuovendo chi non è più passato" do
    described_class.call(action: action, account_ids: [ member_one.id, member_two.id ])
    described_class.call(action: action, account_ids: [ member_two.id ])

    expect(action.reload.participants).to contain_exactly(member_two)
  end

  it "è idempotente su insieme invariato" do
    described_class.call(action: action, account_ids: [ member_one.id ])

    expect { described_class.call(action: action, account_ids: [ member_one.id ]) }
      .not_to change { action.participations.count }
  end

  it "svuota i partecipanti con insieme vuoto" do
    described_class.call(action: action, account_ids: [ member_one.id ])
    described_class.call(action: action, account_ids: [])

    expect(action.reload.participants).to be_empty
  end
end
