# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activity::Event, type: :model do
  it "la factory di default è valida" do
    expect(build(:activity_event)).to be_valid
  end

  describe "validazioni" do
    it "accetta le action nella allow-list" do
      expect(build(:activity_event, action: "updated")).to be_valid
    end

    it "rifiuta una action fuori allow-list" do
      event = build(:activity_event, action: "exploded")
      expect(event).to be_invalid
      expect(event.errors[:action]).to be_present
    end

    it "è invalido se l'organization non combacia col subject (tenant integrity)" do
      project = create(:project)
      other_org = create(:organization)
      event = build(:activity_event, subject: project, organization: other_org)

      expect(event).to be_invalid
      expect(event.errors[:organization]).to be_present
    end

    it "keeps a moved_out event in the source organization after the subject left (CYRA-879)" do
      project = create(:project)
      source = create(:organization)

      expect(build(:activity_event, subject: project, organization: source, action: "moved_out")).to be_valid
      expect(build(:activity_event, subject: project, organization: source, action: "moved_in")).to be_invalid
    end

    it "senza subject salta il controllo org-vs-subject (subject obbligatorio gestito a parte)" do
      # org esplicita per isolare il ramo subject.nil? (altrimenti la factory deriva org dal subject).
      event = build(:activity_event, subject: nil, organization: create(:organization))

      expect(event).to be_invalid                         # subject è comunque obbligatorio
      expect(event.errors[:organization]).to be_empty     # il check org-vs-subject è saltato (subject nil)
    end
  end

  describe "polimorfismo subject" do
    it "lega un Projects::Project come subject" do
      project = create(:project)
      event = create(:activity_event, subject: project, organization: project.organization)

      expect(event.subject).to eq(project)
      expect(event.subject_type).to eq("Projects::Project")
    end
  end

  describe ".chronological" do
    it "ordina per created_at e poi id (tie-break deterministico)" do
      project = create(:project)
      instant = 1.hour.ago
      first  = create(:activity_event, subject: project, organization: project.organization, created_at: instant)
      second = create(:activity_event, subject: project, organization: project.organization, created_at: instant)

      ordered = Activity::Event.where(subject: project).chronological.to_a
      expect(ordered).to eq([ first, second ].sort_by { |event| [ event.created_at, event.id ] })
    end
  end

  describe "#impersonated?" do
    it "true quando true_actor differisce dall'actor" do
      expect(build(:activity_event, :impersonated)).to be_impersonated
    end

    it "false senza true_actor" do
      expect(build(:activity_event, true_actor: nil)).not_to be_impersonated
    end
  end
end
