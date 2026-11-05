# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Goal, type: :model do
  it "factory valida (pageview_path e custom_event)" do
    expect(build(:analytics_goal)).to be_valid
    expect(build(:analytics_goal, :custom_event)).to be_valid
  end

  describe "validazioni" do
    it "richiede display_name" do
      expect(build(:analytics_goal, display_name: " ")).not_to be_valid
    end

    it "pageview_path richiede path_pattern; custom_event richiede event_name" do
      expect(build(:analytics_goal, kind: :pageview_path, path_pattern: nil)).not_to be_valid
      expect(build(:analytics_goal, :custom_event, event_name: nil)).not_to be_valid
    end

    it "event_name unico per progetto (custom_event)" do
      existing = create(:analytics_goal, :custom_event, event_name: "Signup")
      expect(build(:analytics_goal, :custom_event, project: existing.project, event_name: "Signup")).not_to be_valid
      expect(build(:analytics_goal, :custom_event, event_name: "Signup")).to be_valid # altro progetto
    end

    # CYRA-1158 — one event may have one goal per property value.
    it "allows one goal per property value on the same event, and only one without a filter" do
      existing = create(:analytics_goal, :custom_event, event_name: "Signup")
      project = existing.project
      pro = create(:analytics_goal, :custom_event, project:, event_name: "Signup", property_name: "plan", property_value: "pro")
      expect(pro).to be_persisted
      expect(build(:analytics_goal, :custom_event, project:, event_name: "Signup", property_name: "plan", property_value: "free")).to be_valid
      expect(build(:analytics_goal, :custom_event, project:, event_name: "Signup", property_name: "plan", property_value: "pro")).not_to be_valid
    end

    it "requires the property name and value together, and only on event goals" do
      expect(build(:analytics_goal, :custom_event, property_name: "plan", property_value: nil)).not_to be_valid
      expect(build(:analytics_goal, :custom_event, property_name: nil, property_value: "pro")).not_to be_valid
      page_goal = build(:analytics_goal, property_name: "plan", property_value: "pro")
      expect(page_goal).to be_valid
      expect([ page_goal.property_name, page_goal.property_value ]).to eq([ nil, nil ])
    end

    it "path_pattern unico per progetto (pageview_path)" do
      existing = create(:analytics_goal, path_pattern: "/checkout")
      expect(build(:analytics_goal, project: existing.project, path_pattern: "/checkout")).not_to be_valid
    end
  end

  describe "#matching" do
    let(:project) { create(:project) }
    let(:events) { Analytics::Pageview.where(project_id: project.id) }

    def pv(over = {})
      create(:pageview, { project: project }.merge(over))
    end

    it "pageview_path: match esatto del path, solo eventi pageview" do
      hit = pv(path: "/pricing", name: "pageview")
      pv(path: "/other", name: "pageview")
      pv(path: "/pricing", name: "Signup") # custom event sullo stesso path → escluso

      goal = build(:analytics_goal, project: project, path_pattern: "/pricing")
      expect(goal.matching(events).pluck(:id)).to contain_exactly(hit.id)
    end

    it "pageview_path: suffisso '*' = match di prefisso" do
      a = pv(path: "/blog/uno")
      b = pv(path: "/blog/due")
      pv(path: "/altro")

      goal = build(:analytics_goal, project: project, path_pattern: "/blog/*")
      expect(goal.matching(events).pluck(:id)).to contain_exactly(a.id, b.id)
    end

    it "custom_event: match sul nome dell'evento" do
      hit = pv(name: "Signup", path: "/x")
      pv(name: "pageview", path: "/x")

      goal = build(:analytics_goal, :custom_event, project: project, event_name: "Signup")
      expect(goal.matching(events).pluck(:id)).to contain_exactly(hit.id)
    end

    it "custom_event with a property filter counts only events carrying that value" do
      pro = pv(name: "Signup", path: "/x", properties: { "plan" => "pro" })
      pv(name: "Signup", path: "/x", properties: { "plan" => "free" })
      pv(name: "Signup", path: "/x")
      seats = pv(name: "Signup", path: "/x", properties: { "seats" => 3 })

      goal = build(:analytics_goal, :custom_event, project:, event_name: "Signup", property_name: "plan", property_value: "pro")
      expect(goal.matching(events).pluck(:id)).to contain_exactly(pro.id)
      numeric = build(:analytics_goal, :custom_event, project:, event_name: "Signup", property_name: "seats", property_value: "3")
      expect(numeric.matching(events).pluck(:id)).to contain_exactly(seats.id)
    end
  end
end
