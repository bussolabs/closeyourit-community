# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatReferenceCardComponent, type: :component do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, key: "ABC") }

  it "non renderizza nulla se referable è nil" do
    render_inline(described_class.new(referable: nil))
    expect(page).not_to have_css("a")
  end

  it "renderizza un progetto (key + link)" do
    render_inline(described_class.new(referable: project))
    expect(page).to have_link(href: "/member/projects/#{project.id}")
    expect(page).to have_content(project.key)
  end

  it "renderizza un ticket col codice" do
    ticket = create(:ticket, organization: org, project: project)
    render_inline(described_class.new(referable: ticket))
    expect(page).to have_link(href: "/member/tickets/#{ticket.id}")
    expect(page).to have_content(ticket.code)
  end

  it "renderizza un error group non risolto (badge rosso)" do
    group = create(:error_group, project: project)
    render_inline(described_class.new(referable: group))
    expect(page).to have_link(href: "/member/monitoring/error/#{group.id}")
  end

  it "renderizza un error group risolto (colore emerald)" do
    group = create(:error_group, project: project, status: :resolved)
    render_inline(described_class.new(referable: group))
    expect(page).to have_css("[data-test='chat-reference-card']")
    expect(page).to have_css(".bg-emerald-50", text: "resolved")
  end

  it "renderizza un error group ignorato (colore gray)" do
    group = create(:error_group, project: project, status: :ignored)
    render_inline(described_class.new(referable: group))
    expect(page).to have_css("[data-test='chat-reference-card']")
    expect(page).to have_css(".bg-gray-100", text: "ignored")
  end

  describe "visible: false (revoca accesso live)" do
    it "renderizza il placeholder senza label, stato né link" do
      ticket = create(:ticket, organization: org, project: project)
      render_inline(described_class.new(referable: ticket, visible: false))

      expect(page).to have_css("[data-test='chat-reference-unavailable']")
      expect(page).not_to have_css("a")
      expect(page).not_to have_content(ticket.code)
    end
  end

  it "renderizza un metric group" do
    group = create(:metric_group, project: project)
    render_inline(described_class.new(referable: group))
    expect(page).to have_link(href: "/member/monitoring/performance/#{group.id}")
  end

  it "renderizza un log entry" do
    entry = create(:log_entry, project: project)
    render_inline(described_class.new(referable: entry))
    expect(page).to have_link(href: "/member/monitoring/logs/#{entry.id}")
  end

  it "renderizza un uptime monitor" do
    monitor = create(:uptime_monitor, project: project)
    render_inline(described_class.new(referable: monitor))
    expect(page).to have_link(href: "/member/monitoring/monitors/#{monitor.id}")
  end
end
