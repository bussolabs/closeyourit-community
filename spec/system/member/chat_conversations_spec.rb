# frozen_string_literal: true

require "rails_helper"

# The two parts of the conversations page that only happen in the browser: the list search and the
# viewer's own messages on the right. Gated by spec/support/js_system.rb (JS_SYSTEM_SPECS=1).
RSpec.describe "Member conversations in the browser", :js, type: :system do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Storefront") }

  def member(name)
    account = create(:account, name: name)
    create(:membership, account: account, organization: org, role: :member)
    create(:project_membership, account: account, project: project)
    account
  end

  let(:me) { member("Alice Viewer") }
  let(:marta) { member("Marta Rossi") }
  let!(:direct) do
    Chat::Conversations::FindOrCreateDirect.call(organization: org, account_a: me, account_b: marta).value
  end
  let!(:channel) do
    Chat::Conversations::FindOrCreateChannel.call(organization: org, contextable: project, actor: me).value
  end

  it "narrows the list to the conversations that match the search" do
    sign_in_as(me)
    visit member_chat_conversations_path

    find("[data-test='chat-pane-search']").fill_in(with: "storefront")

    expect(page).to have_css("[data-test='chat-conversation-link-#{channel.id}']")
    expect(page).to have_no_css("[data-test='chat-conversation-link-#{direct.id}']")

    find("[data-test='chat-pane-search']").fill_in(with: "nothing like this")
    expect(page).to have_css("[data-test='chat-pane-search-empty']", text: I18n.t("member.chat.search_empty"))
  end

  it "puts my messages on the right and the others on the left" do
    mine = create(:chat_message, conversation: direct, author: me, body: "Mine")
    theirs = create(:chat_message, conversation: direct, author: marta, body: "Theirs")
    sign_in_as(me)
    visit member_chat_conversation_path(direct)

    expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(mine)}.ml-auto")
    expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(theirs)}.mr-auto")
  end

  it "adds a Today separator above a live message from a new day" do
    create(:chat_message, conversation: direct, author: marta, body: "Old", created_at: 1.day.ago)
    sign_in_as(me)
    visit member_chat_conversation_path(direct)
    expect(page).to have_css("[data-test='chat-day']", count: 1)

    # Same markup a broadcast appends: a message from today after yesterday's separator.
    live = create(:chat_message, conversation: direct, author: marta, body: "Live")
    html = ApplicationController.render(partial: "member/chat_conversations/message",
                                        locals: { message: live, conversation: direct })
    page.execute_script("document.querySelector(\"[data-test='chat-messages']\").insertAdjacentHTML('beforeend', arguments[0])", html)

    expect(page).to have_css("[data-test='chat-day']", count: 2)
    expect(all("[data-test='chat-day']").last).to have_text(I18n.t("member.chat.days.today"))
  end

  def append_live_message(message)
    html = ApplicationController.render(partial: "member/chat_conversations/message",
                                        locals: { message: message, conversation: direct })
    page.execute_script("document.querySelector(\"[data-test='chat-messages']\").insertAdjacentHTML('beforeend', arguments[0])", html)
  end

  it "adds a Today separator above the first live message of an empty thread" do
    sign_in_as(me)
    visit member_chat_conversation_path(direct)
    expect(page).to have_css("[data-test='chat-empty-thread']")

    append_live_message(create(:chat_message, conversation: direct, author: marta, body: "First"))

    expect(page).to have_css("[data-test='chat-day']", count: 1, text: I18n.t("member.chat.days.today"))
  end

  it "relabels the old Today separator once a message arrives after midnight" do
    create(:chat_message, conversation: direct, author: marta, body: "Before midnight")
    sign_in_as(me)
    visit member_chat_conversation_path(direct)
    expect(page).to have_css("[data-test='chat-day']", count: 1, text: I18n.t("member.chat.days.today"))

    append_live_message(create(:chat_message, conversation: direct, author: marta, body: "After midnight",
                                              created_at: 1.day.from_now))

    expect(page).to have_css("[data-test='chat-day']", count: 2)
    expect(all("[data-test='chat-day']").map(&:text))
      .to eq([ I18n.t("member.chat.days.yesterday"), I18n.t("member.chat.days.today") ])
  end
end
