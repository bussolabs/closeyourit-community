# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the ticket tabs after the refactor: tab order and signals on the strip, no panel title
# that repeats the tab name, and each tab's own layout choices.
RSpec.describe "Member ticket tabs layout", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:owner) { create(:account, name: "Marta Rossi") }

  before do
    create(:membership, :owner, organization:, account: owner)
    create(:project_membership, project:, account: owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def page_html = Nokogiri::HTML5(response.body)

  def position(test_id) = response.body.index(%(data-test="#{test_id}"))

  describe "tab strip" do
    it "puts Discussion right after Detail" do
      get member_ticket_path(ticket)

      tabs = page_html.css('[data-test="ticket-tabs"] a').map { |link| link["data-test"] }
      expect(tabs.first(4)).to eq(%w[ticket-tab-detail ticket-tab-discussion ticket-tab-questions ticket-tab-automation])
    end

    it "sits inside the page header, on its bottom row" do
      get member_ticket_path(ticket)

      expect(page_html.at_css('[data-test="page-header-bottom"] [data-test="ticket-tabs"] [data-test="ticket-tab-detail"]')["aria-current"]).to eq("page")
      expect(page_html.css('[data-test="member-ticket"] > nav')).to be_empty
    end

    it "keeps the live comment count on the Discussion tab" do
      create(:ticket_comment, ticket:)

      get member_ticket_path(ticket)

      expect(page_html.at_css(%([data-test="ticket-tab-discussion"] #ticket_comments_count_#{ticket.id})).text.strip).to eq("1")
    end

    it "marks Automation when the work waits for a person" do
      workflow = create(:ticket, organization:, project:, with_agent_workflow: true)
      workflow.agent_workflow.update!(triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)

      get member_ticket_path(workflow)

      expect(response.body).to include('data-test="ticket-tab-automation-attention"')
    end

    it "leaves Automation unmarked when there is no work" do
      get member_ticket_path(ticket)

      expect(response.body).not_to include('data-test="ticket-tab-automation-attention"')
    end

    it "shows the report version on its tab" do
      Ticketing::RecordReport.call(ticket:, author: owner, body: "Stesura 1.")
      Ticketing::RecordReport.call(ticket:, author: owner, body: "Stesura 2.")

      get member_ticket_path(ticket)

      expect(page_html.at_css('[data-test="ticket-tab-report-version"]').text.strip).to eq("v2")
    end
  end

  describe "scenarios on the detail" do
    it "writes each scenario as one block: number and title on top, the four clauses as rows" do
      create(:ticketing_scenario, ticket:, title: "Checkout", step_given: "a cart", step_when: "I pay", step_then: "it hangs", step_expected: "it pays")

      get member_ticket_path(ticket)

      block = page_html.at_css('[data-test="ticket-scenarios"] [data-test="ticket-scenario"]')
      expect(block["class"]).to include("rounded-md", "border")
      expect(block.at_css('[data-test="ticket-scenario-number"]').text.strip).to eq("1")
      expect(block.css('[data-test^="ticket-scenario-step-"]').map { it["data-test"] })
        .to eq(%w[ticket-scenario-step-given ticket-scenario-step-when ticket-scenario-step-then ticket-scenario-step-expected])
      expect(block.at_css('[data-test="ticket-scenario-step-expected"]')["class"]).to include("bg-indigo-50")
    end
  end

  describe "technical analysis tab" do
    before { ticket.update!(technical_analysis: "## Causa\n\nNessun tempo massimo.\n\n## Proposta\n\nOtto secondi.") }

    it "drops the panel title and keeps who wrote it above the text" do
      get member_ticket_path(ticket, tab: "analysis")

      titles = page_html.css('[data-test="ticket-technical-analysis"] h2').map { |node| node.text.strip }
      expect(titles).not_to include(I18n.t("member.tickets.show.technical_analysis"))
      expect(position("ticket-analysis-signature")).to be < position("ticket-technical-analysis")
    end

    it "lists the sections and links them to anchored headings" do
      get member_ticket_path(ticket, tab: "analysis")

      toc = page_html.css('[data-test="ticket-analysis-toc"] a').map { |link| [ link.text.strip, link["href"] ] }
      expect(toc).to eq([ [ "Causa", "#analysis-causa" ], [ "Proposta", "#analysis-proposta" ] ])
      expect(page_html.at_css("#analysis-causa")).to be_present
    end

    it "offers edit and copy to whoever can change the ticket" do
      get member_ticket_path(ticket, tab: "analysis")

      expect(page_html.at_css('[data-test="ticket-analysis-edit"]')["href"]).to eq(edit_member_ticket_path(ticket))
      expect(page_html.at_css('[data-test="ticket-analysis-source"]').text).to include("## Causa")
      expect(response.body).to include('data-test="ticket-analysis-copy"')
    end
  end

  describe "report tab" do
    before do
      Ticketing::RecordReport.call(ticket:, author: owner, body: "**Fatto:** prima stesura.\n\n**Rischi:** nessuno.")
      Ticketing::RecordReport.call(ticket:, author: owner, body: "**Fatto:** seconda stesura.\n\n**Rischi:** nessuno.")
    end

    it "keeps version and author on one line, without a panel title" do
      get member_ticket_path(ticket, tab: "report")

      expect(page_html.css('[data-test="ticket-report"] h2')).to be_empty
      expect(page_html.at_css('[data-test="ticket-report-meta"]').text).to include("Marta Rossi")
    end

    it "moves earlier versions into a menu" do
      get member_ticket_path(ticket, tab: "report")

      menu = page_html.at_css('[data-test="ticket-report-versions-menu"]')
      expect(menu.css("a").map { |link| link["href"] }).to include(member_ticket_report_version_path(ticket, 1))
    end

    it "turns bold labels into section headings" do
      get member_ticket_path(ticket, tab: "report")

      headings = page_html.css('[data-test="ticket-report"] h4').map { |node| node.text.strip }
      expect(headings).to eq(%w[Fatto Rischi])
    end

    it "shows what changed since the previous version" do
      get member_ticket_path(ticket, tab: "report")

      diff = page_html.at_css('[data-test="ticket-report-diff"]')
      expect(diff.css('[data-test="ticket-report-diff-added"]').text).to include("seconda stesura")
      expect(diff.css('[data-test="ticket-report-diff-removed"]').text).to include("prima stesura")
    end
  end

  describe "automation tab" do
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }

    before { organization.update!(cto: owner) }

    it "opens with the phase strip and one line with who decides" do
      get member_ticket_path(ticket, tab: "automation")

      summary = page_html.at_css('[data-test="automation-summary"]')
      expect(summary.at_css('[data-test="approval-phase-strip"]')).to be_present
      expect(summary.at_css('[data-test="automation-summary-strip"]').text).to include("Marta Rossi")
      expect(response.body).not_to include('data-test="ticket-automation"')
    end

    it "shows the plan before the steps" do
      attempt = create(:agent_attempt, organization:, workflow:)
      workflow.update!(ticket_snapshot_digest: "snapshot")
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot", contract_version: 2,
                           technical_analysis: "Analisi", content: { "summary" => "Piano breve.", "work_items" => [],
                                                                     "rationale" => [], "risks" => [], "open_points" => [], "sources" => [] },
                           scenarios: [], definition_of_done: [ { "id" => "DOD-1", "text" => "Fatto" } ], notes: [])

      get member_ticket_path(ticket, tab: "automation")

      expect(position("automation-plan")).to be < position("automation-steps")
    end

    it "sends the agent work report to the Report tab" do
      create(:agent_attempt, organization:, workflow:, phase: "autopilot", status: :approved,
                             result: { "work_report" => { "summary" => "Foto modificabili.", "changed_files" => [],
                                                          "tests" => [], "risks" => [], "deviations" => [] } })

      get member_ticket_path(ticket, tab: "automation")
      expect(response.body).not_to include('data-test="automation-work-report"')
      expect(response.body).to include('data-test="automation-work-report-moved"')

      get member_ticket_path(ticket, tab: "report")
      expect(response.body).to include('data-test="automation-work-report"', "Foto modificabili.")
      expect(response.body).to include('data-test="ticket-tab-report"')
    end

    it "keeps reassess and close on one row, with the reason behind a click" do
      get member_ticket_path(ticket, tab: "automation")

      actions = page_html.at_css('[data-test="automation-actions"]')
      expect(actions.at_css('details [data-test="automation-cancel"]')).to be_present
      expect(response.body).to include('data-test="automation-cancel-effect"')
    end
  end

  describe "questions tab" do
    let(:asker) { create(:account).tap { |account| create(:membership, account:, organization:, role: :member) } }

    it "drops the title, keeps the open count by the form and folds settled questions" do
      open_question = Ticketing::Question.create!(ticket:, author: asker, body: "Quale strada?")
      settled = Ticketing::Question.create!(ticket:, author: asker, body: "Già risolta?", answered_at: Time.current)

      get member_ticket_path(ticket, tab: "questions")

      section = page_html.at_css('[data-test="ticket-questions"]')
      expect(section.css("h2")).to be_empty
      expect(section.at_css('form [data-test="ticket-questions-open-count"]')).to be_present
      expect(section.at_css(%(details[data-test="ticket-questions-settled"] [data-test="ticket-question-#{settled.id}"]))).to be_present
      expect(section.at_css(%(details [data-test="ticket-question-#{open_question.id}"]))).to be_nil
    end

    it "puts the help sentence in the field instead of below it" do
      get member_ticket_path(ticket, tab: "questions")

      expect(page_html.at_css('[data-test="ticket-question-body"]')["placeholder"]).to eq(I18n.t("member.tickets.questions.placeholder"))
      expect(response.body).to include('data-test="ticket-question-options"')
    end
  end

  describe "discussion tab" do
    it "drops the title and offers a comments-only filter" do
      create(:ticket_comment, ticket:, author: owner)

      get member_ticket_path(ticket, tab: "discussion")

      expect(page_html.css('[data-test="member-ticket-comments"] h2')).to be_empty
      expect(response.body).to include('data-test="member-ticket-timeline-filter"')
    end

    it "folds system events in a row into one line" do
      3.times { create(:ticket_event, ticket:) }

      get member_ticket_path(ticket, tab: "discussion")

      group = page_html.at_css('details[data-test="member-ticket-event-group"]')
      expect(group).to be_present
      expect(group.css('[data-test^="member-ticket-event-"]').size).to be >= 3
    end

    it "shows relative dates with the exact time on hover" do
      create(:ticket_comment, ticket:, author: owner, created_at: 2.hours.ago)

      get member_ticket_path(ticket, tab: "discussion")

      time = page_html.at_css('[data-test="member-ticket-comment-time"]')
      expect(time.text.strip).to eq(I18n.t("member.home.time_ago", time: "about 2 hours"))
      expect(time["title"]).to match(%r{\A\d{2}/\d{2} · \d{2}:\d{2}\z})
    end

    it "keeps the length sentence for when the comment nears its limit" do
      get member_ticket_path(ticket, tab: "discussion")

      hint = page_html.at_css('[data-test="member-ticket-comment-hint"]')
      expect(hint["data-char-counter-target"]).to eq("hint")
      expect(hint["class"]).to include("hidden")
      expect(response.body).to include('data-test="member-ticket-comment-extras"')
    end

    it "shows Comment only once the field is in use, under it, and offers dictation" do
      get member_ticket_path(ticket, tab: "discussion")

      extras = page_html.at_css('[data-test="member-ticket-comment-extras"]')
      expect(extras["class"]).to include("hidden", "group-focus-within/compose:block")
      expect(extras.at_css('[data-test="member-ticket-comment-submit"]')).to be_present
      form = page_html.at_css('[data-test="member-ticket-comment-form"]')
      expect(form.at_css('[data-test="dictation-mic"]')).to be_present
      expect(form.at_css('[data-test="member-ticket-comment-body"]')["data-ui--voice-inline-target"]).to eq("input")
    end
  end
end
