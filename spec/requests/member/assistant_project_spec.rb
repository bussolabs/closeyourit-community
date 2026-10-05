# frozen_string_literal: true

require "rails_helper"

# A conversation opened from a project stays fixed on it: the panel says so, the conversation
# remembers it and every reply reads that project only.
RSpec.describe "Member::Assistant on a project", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: org, key: "DASH", name: "Dashboard") }
  let(:foreign) { create(:project, organization: create(:organization), name: "Elsewhere") }

  before do
    create(:membership, account:, organization: org, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  describe "the button on the project header" do
    it "is an icon-only button that carries the panel address of this project" do
      get member_project_path(project)

      button = html.at_css("[data-test='project-ask']")
      expect(button["data-assistant-project-url"]).to eq(member_assistant_panel_path(project_id: project.id))
      expect(button["aria-label"]).to eq(I18n.t("member.projects.show.ask_assistant"))
      expect(button.text.strip).to be_empty
    end
  end

  describe "GET panel with a project" do
    it "names the project and sends the first message to a conversation fixed on it" do
      get member_assistant_panel_path(project_id: project.id)

      expect(html.at_css("[data-test='assistant-project']").text).to include("Dashboard")
      expect(html.at_css("form:has([data-test='assistant-input'])")["action"])
        .to eq(member_assistant_conversations_path(project_id: project.id))
    end

    it "reopens the latest conversation fixed on that project, not the latest of all" do
      pinned = Assistant::Conversation.create!(account:, organization: org, project: project,
                                               last_message_at: 2.days.ago)
      Assistant::Conversation.create!(account:, organization: org, last_message_at: 1.minute.ago)

      get member_assistant_panel_path(project_id: project.id)

      expect(html.at_css("form:has([data-test='assistant-input'])")["action"])
        .to eq(member_assistant_conversation_messages_path(pinned))
    end

    it "ignores a project the account cannot see" do
      get member_assistant_panel_path(project_id: foreign.id)

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-test='assistant-project']")).to be_nil
    end

    it "shows no project on a plain panel" do
      get member_assistant_panel_path

      expect(html.at_css("[data-test='assistant-project']")).to be_nil
    end

    it "shows the project of the conversation it reopens" do
      Assistant::Conversation.create!(account:, organization: org, project: project, last_message_at: Time.current)

      get member_assistant_panel_path

      expect(html.at_css("[data-test='assistant-project']").text).to include("Dashboard")
    end
  end

  describe "POST create with a project" do
    it "fixes the new conversation on the project and reads that project only" do
      create(:project, organization: org, name: "Other")

      expect { post member_assistant_conversations_path, params: { project_id: project.id, text: "errors?" } }
        .to have_enqueued_job(Assistant::ConverseJob)
        .with(hash_including(project_ids: [ project.id ], group_ids: [], full_access: false))

      expect(Assistant::Conversation.last.project).to eq(project)
    end

    it "creates a plain conversation for a project the account cannot see" do
      post member_assistant_conversations_path, params: { project_id: foreign.id }

      expect(Assistant::Conversation.last.project).to be_nil
    end
  end

  describe "GET show" do
    it "names the project the conversation is fixed on" do
      conversation = Assistant::Conversation.create!(account:, organization: org, project: project)

      get member_assistant_conversation_path(conversation)

      expect(html.at_css("[data-test='assistant-project']").text).to include("Dashboard")
    end
  end
end
