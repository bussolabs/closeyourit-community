# frozen_string_literal: true

require "rails_helper"

RSpec.describe Replays::PruneJob, type: :job do
  let(:project) { create(:project) }

  def session_at(replay_session_id, created_at)
    session = project.replay_sessions.create!(replay_session_id:, started_at: created_at)
    gz = ActiveSupport::Gzip.compress("[]")
    session.chunks.attach(io: StringIO.new(gz), filename: "#{replay_session_id}-0.json.gz",
                          content_type: "application/gzip")
    session.update_column(:created_at, created_at)
    session
  end

  it "elimina le sessioni oltre la retention di default e stacca gli attachment" do
    old = session_at("old", 40.days.ago)
    recent = session_at("new", 5.days.ago)

    expect { described_class.perform_now }.to change(Replays::Session, :count).by(-1)
    expect(Replays::Session.exists?(recent.id)).to be(true)
    expect(Replays::Session.exists?(old.id)).to be(false)
    expect(ActiveStorage::Attachment.where(record_type: "Replays::Session", record_id: old.id)).to be_empty
  end

  it "rispetta la retention custom del progetto (pref più lunga → non pota)" do
    project.update!(replay_retention_days: 90)
    session_at("old", 40.days.ago)

    expect { described_class.perform_now }.not_to change(Replays::Session, :count)
  end
end
