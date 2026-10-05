# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::PromoteToTicket, type: :service do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:site) { create(:seo_site, project:) }
  let(:page) { create(:seo_page, site:, url: "https://esempio.test/chi-siamo") }
  let(:issue) do
    create(:seo_issue, site:, page:, check_key: "missing_h1", severity: :high,
                       evidence: { "url" => page.url, "found" => 0 })
  end

  before do
    create(:membership, account: owner, organization:, role: :owner)
    create(:ticket_status, organization:, code: "open", position: 0)
    create(:ticket_priority, organization:, code: "high", position: 0)
  end

  it "apre un ticket collegato al rilievo" do
    result = described_class.call(issue:, reporter: owner)

    expect(result).to be_ok
    expect(issue.reload).to be_promoted
    expect(issue.ticket.project).to eq(project)
  end

  it "il titolo dice cosa non va e dove, senza gergo" do
    described_class.call(issue:, reporter: owner)

    expect(issue.reload.ticket.title).to include(issue.label)
    expect(issue.ticket.title).to include("/chi-siamo")
  end

  it "l'analisi tecnica porta la prova, così nessuno deve rifarla a mano" do
    described_class.call(issue:, reporter: owner)

    analysis = issue.reload.ticket.technical_analysis
    expect(analysis).to include("missing_h1", "structure", page.url, site.base_url)
    expect(analysis).to include("found")
  end

  it "lo scenario racconta cosa si apre e cosa dovrebbe succedere" do
    described_class.call(issue:, reporter: owner)

    scenario = issue.reload.ticket.scenarios.first
    expect(scenario.step_when).to include(page.url)
    expect(scenario.step_expected).to be_present
  end

  it "promuovere due volte non apre due ticket" do
    first = described_class.call(issue:, reporter: owner)
    second = described_class.call(issue: issue.reload, reporter: owner)

    expect(second).not_to be_ok
    expect(issue.reload.ticket_id).to eq(first.value.id)
  end

  it "un rilievo d'insieme, che non ha una pagina, si promuove lo stesso" do
    whole_site = create(:seo_issue, :site_scoped, site:)

    result = described_class.call(issue: whole_site, reporter: owner)

    expect(result).to be_ok
    expect(whole_site.reload).to be_promoted
  end
end
