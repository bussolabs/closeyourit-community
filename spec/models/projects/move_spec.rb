# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Move do
  let(:source) { create(:organization) }
  let(:destination) { create(:organization) }
  let(:project) { create(:project, organization: source) }

  it "allows only one active move per subject" do
    create(:project_move, subject: project, source_organization: source, destination_organization: destination)
    duplicate = build(:project_move, subject: project, source_organization: source, destination_organization: destination)

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a new move once the previous one has finished" do
    create(:project_move, subject: project, source_organization: source, destination_organization: destination,
                          status: :succeeded)
    expect(build(:project_move, subject: project, source_organization: source,
                                destination_organization: destination)).to be_valid
  end

  it "rejects a destination equal to the source" do
    move = build(:project_move, subject: project, source_organization: source, destination_organization: source)
    expect(move).not_to be_valid
  end

  describe ".expire_stale!" do
    def move_with(status, updated_at)
      create(:project_move, status:).tap { _1.update_columns(updated_at:) }
    end

    it "fails a running move that has not been touched for too long" do
      stale = move_with(:running, 20.minutes.ago)

      expect(described_class.expire_stale!).to eq(1)
      expect(stale.reload).to have_attributes(status: "failed", error_message: "interrupted")
      expect(stale.finished_at).to be_present
    end

    it "fails a pending move whose job never ran" do
      stale = move_with(:pending, 20.minutes.ago)

      expect(described_class.expire_stale!).to eq(1)
      expect(stale.reload).to have_attributes(status: "failed", error_message: "interrupted")
    end

    it "leaves fresh running and pending moves and finished ones alone" do
      moves = [ move_with(:running, 5.minutes.ago), move_with(:pending, 5.minutes.ago), move_with(:succeeded, 1.hour.ago) ]

      expect(described_class.expire_stale!).to eq(0)
      expect(moves.map { _1.reload.status }).to eq(%w[running pending succeeded])
    end
  end
end
