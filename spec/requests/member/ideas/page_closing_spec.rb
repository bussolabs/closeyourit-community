# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Idea page: audit strip and comment field", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }
  let(:idea) { create(:idea, organization: org, project: create(:project, organization: org), author: owner) }

  before do
    post login_path, params: { email: owner.email, password: "Secret123!" }
    get member_idea_path(idea)
  end

  it "closes the page with the audit strip, in a panel of its own, after both columns" do
    html = Capybara.string(response.body)

    expect(html).to have_css("[data-test='idea-audit'] [data-test='idea-audit-meta']")
    expect(html).to have_no_css("[data-test='idea-side-column'] [data-test='idea-audit-meta']")
    expect(response.body.index('data-test="idea-side-column"')).to be < response.body.index('data-test="idea-audit"')
  end

  it "has the ticket's comment field: one line, Comment only once in use, dictation" do
    form = Capybara.string(response.body).find("[data-test='member-idea-comment-form']")

    expect(form.find("[data-test='member-idea-comment-body']")["data-ui--voice-inline-target"]).to eq("input")
    expect(form).to have_css("[data-test='dictation-mic']", visible: :all)
    extras = form.find("[data-test='member-idea-comment-extras']", visible: :all)
    expect(extras[:class]).to include("hidden", "group-focus-within/compose:flex")
    expect(extras).to have_css("[data-test='member-idea-comment-submit']", visible: :all)
  end
end
