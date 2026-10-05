require "rails_helper"

RSpec.describe Secrets::Event, type: :model do
  it "la factory produce un evento valido" do
    expect(build(:secret_event)).to be_valid
  end

  describe "validazioni" do
    it "accetta solo le action ammesse" do
      Secrets::Event::ACTIONS.each do |action|
        expect(build(:secret_event, action:)).to be_valid
      end
      expect(build(:secret_event, action: "boom")).not_to be_valid
    end

    it "richiede un progetto" do
      expect(build(:secret_event, project: nil, organization: nil)).not_to be_valid
    end

    it "actor ed environment sono opzionali (eventi bundle-level / di sistema)" do
      expect(build(:secret_event, actor: nil, environment: nil)).to be_valid
    end

    # CYRA-78 — il canale dice da dove arrivava il tentativo; resta nil dove non è noto.
    it "il canale è opzionale e ammette solo web o cli" do
      expect(build(:secret_event, channel: nil)).to be_valid
      Secrets::Event::CHANNELS.each { |channel| expect(build(:secret_event, channel:)).to be_valid }
      expect(build(:secret_event, channel: "telepatia")).not_to be_valid
    end
  end

  describe ".recent" do
    it "ordina dal più recente" do
      project = create(:project)
      old = create(:secret_event, project:, organization: project.organization, created_at: 2.days.ago)
      fresh = create(:secret_event, project:, organization: project.organization, created_at: 1.hour.ago)
      expect(project.secret_events.recent.to_a).to eq([ fresh, old ])
    end
  end
end
