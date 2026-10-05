# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::WorkloadParticipant, type: :model do
  let(:organization) { create(:organization) }
  let(:team) { create(:team, organization: organization) }
  let(:action) { create(:workload_action, team: team, organization: organization) }

  describe "unicità" do
    it "impedisce lo stesso account due volte sulla stessa action" do
      participant = create(:connections_workload_participant)
      duplicate = build(:connections_workload_participant, action: participant.action, account: participant.account)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:account_id]).to be_present
    end
  end

  describe "#account_belongs_to_action_team" do
    it "è valida se l'account è membro del team della action" do
      account = create(:account)
      create(:team_membership, team: team, account: account)

      expect(build(:connections_workload_participant, action: action, account: account)).to be_valid
    end

    it "è invalida se l'account non è membro del team della action" do
      outsider = create(:account)

      participant = described_class.new(action: action, account: outsider)

      expect(participant).not_to be_valid
      expect(participant.errors[:account]).to be_present
    end
  end
end
