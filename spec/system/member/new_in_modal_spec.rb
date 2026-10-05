# frozen_string_literal: true

require "rails_helper"

# CYRA-933 — a New opens in the modal over the page, Cancel closes it, a save leaves it.
RSpec.describe "New forms in the member modal", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account).tap { create(:membership, account: it, organization: org, role: :owner) } }

  it "opens New group in the modal, closes on Cancel and leaves it on save" do
    sign_in_as(owner)
    visit member_groups_path

    find("[data-test='groups-new']").click
    within("dialog[data-test='member-modal'][open]") { expect(page).to have_css("[data-test='group-form']") }
    expect(page).to have_current_path(member_groups_path)

    within("dialog[data-test='member-modal']") { click_on I18n.t("member.groups.form.cancel") }
    expect(page).to have_no_css("dialog[data-test='member-modal'][open]")

    find("[data-test='groups-new']").click
    within("dialog[data-test='member-modal'][open]") do
      find("[data-test='group-name']").fill_in(with: "DriverOne")
      find("[data-test='group-submit']").click
    end

    expect(page).to have_no_css("dialog[data-test='member-modal'][open]")
    expect(page).to have_css("[data-test='flash-notice']")
    expect(Projects::Group.where(name: "DriverOne", organization: org)).to exist
  end

  it "creates a group from New project in a modal stacked on top, then picks it" do
    sign_in_as(owner)
    visit member_projects_path

    find("[data-test='projects-new']").click
    within("dialog[data-test='member-modal'][open]") { find("[data-test='project-group-new']").click }
    within("dialog[data-test='member-modal-stack'][open]") do
      find("[data-test='group-name']").fill_in(with: "Stacked group")
      find("[data-test='group-submit']").click
    end

    expect(page).to have_no_css("dialog[data-test='member-modal-stack'][open]")
    group = Projects::Group.find_by!(name: "Stacked group", organization: org)
    within("dialog[data-test='member-modal'][open]") do
      expect(find("select[name='group_id']", visible: :all).value).to eq(group.id)
    end
  end

  it "opens New ticket wide and keeps what was typed when the modal is closed by mistake" do
    create(:project, organization: org)
    sign_in_as(owner)
    visit member_tickets_path

    find("[data-test='tickets-new']").click
    expect(page).to have_css("dialog[data-test='member-modal'][open][data-size='wide']")
    within("dialog[data-test='member-modal'][open]") { find("[data-test='ticket-title']").fill_in(with: "Draft kept") }
    find("body").send_keys(:escape)
    expect(page).to have_no_css("dialog[data-test='member-modal'][open]")

    find("[data-test='tickets-new']").click
    within("dialog[data-test='member-modal'][open]") { expect(page).to have_field("title", with: "Draft kept") }
  end

  it "brings back a scenario added by hand, not only the fields the empty form starts with" do
    create(:project, organization: org)
    sign_in_as(owner)
    visit member_tickets_path

    find("[data-test='tickets-new']").click
    within("dialog[data-test='member-modal'][open]") do
      find("[data-test='ticket-scenario-add']").click
      find("[data-test='ticket-scenario-title']").fill_in(with: "Scenario kept")
    end
    find("body").send_keys(:escape)
    expect(page).to have_no_css("dialog[data-test='member-modal'][open]")

    find("[data-test='tickets-new']").click
    within("dialog[data-test='member-modal'][open]") do
      expect(page).to have_css("[data-test='ticket-scenario-row']", count: 1)
      expect(find("[data-test='ticket-scenario-title']").value).to eq("Scenario kept")
    end
  end

  it "keeps drafts apart per account and organization, and drops the old shared ones" do
    create(:project, organization: org)
    sign_in_as(owner)
    page.execute_script("localStorage.setItem('member-modal-draft:/member/tickets/new', '[]')")
    visit member_tickets_path

    find("[data-test='tickets-new']").click
    within("dialog[data-test='member-modal'][open]") { find("[data-test='ticket-title']").fill_in(with: "Mine only") }
    find("body").send_keys(:escape)

    keys = page.evaluate_script("Object.keys(localStorage).filter((key) => key.startsWith('member-modal-draft:'))")
    expect(keys).to eq([ "member-modal-draft:#{owner.id}:#{org.id}:/member/tickets/new" ])
  end

  it "keeps the header of the form at the top of the modal while it scrolls" do
    create(:project, organization: org)
    sign_in_as(owner)
    # Short enough for the ticket form to scroll inside the modal.
    page.current_window.resize_to(1280, 640)
    visit member_tickets_path

    find("[data-test='tickets-new']").click
    within("dialog[data-test='member-modal'][open]") { expect(page).to have_css("[data-test='ticket-submit']") }
    gap = page.evaluate_script(<<~JS)
      (() => {
        const dialog = document.querySelector("dialog[data-test='member-modal']")
        dialog.scrollTop = dialog.scrollHeight
        return dialog.querySelector("header").getBoundingClientRect().top - dialog.getBoundingClientRect().top
      })()
    JS

    expect(gap).to be_between(0, 2)
    within("dialog[data-test='member-modal'][open]") { expect(page).to have_css("[data-test='ticket-submit']", visible: true) }
  end

  it "offers Write it for me as a tab of New ticket, not as a second modal" do
    create(:project, organization: org)
    sign_in_as(owner)
    visit member_tickets_path

    find("[data-test='tickets-new']").click
    within("dialog[data-test='member-modal'][open]") do
      expect(page).to have_css("[data-test='ticket-title']", visible: true)
      find("[data-test='ticket-compose-open']").click
      expect(page).to have_css("[data-test='ticket-compose-prompt']", visible: true)
      expect(page).to have_no_css("[data-test='ticket-title']", visible: true)
      expect(page).to have_no_css("dialog")

      find("[data-test='ticket-manual-open']").click
      expect(page).to have_css("[data-test='ticket-title']", visible: true)
    end
  end

  it "adds a scenario on request and saves it with the ticket" do
    project = create(:project, organization: org)
    create(:ticket_status, organization: org, code: "open")
    create(:ticket_priority, organization: org, code: "medium")
    sign_in_as(owner)
    visit member_tickets_path
    # A draft left by another example would be restored over what is picked here.
    page.execute_script("localStorage.clear()")

    find("[data-test='tickets-new']").click
    within("dialog[data-test='member-modal'][open]") do
      expect(page).to have_css("[data-test='ticket-form']")
      expect(page).to have_no_css("[data-test='ticket-scenario-row']")
      find("[data-test='ticket-title']").fill_in(with: "With a scenario")
      find("[data-test='ticket-scenario-add']").click
      %w[given when then].each { find("[data-test='ticket-scenario-#{it}']").fill_in(with: "Step #{it}") }
      find("[data-test='ticket-scenario-expected']").fill_in(with: "Checkout opens")
      select project.name, from: "project_id"
      find("[data-test='ticket-submit']").click
    end

    expect(page).to have_css("[data-test='flash-notice']")
    expect(Ticketing::Ticket.find_by!(title: "With a scenario").scenarios.first.step_expected).to eq("Checkout opens")
  end

  # Turbo prefetches on hover: the prefetched answer must be the form for the modal, not the full page.
  it "opens a select of the modal over the modal's edge instead of cutting it" do
    sign_in_as(owner)
    visit member_members_path

    find("[data-test='member-invite']").click
    within("dialog[data-test='member-modal'][open]") do
      find("button[aria-haspopup='listbox']", match: :first).click
      expect(page).to have_css("[role='listbox'] [role='option']", visible: :visible, minimum: 2)
    end

    # Every option lies inside the viewport and is the topmost element at its own centre.
    reachable = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("dialog[open] [role='listbox'] [role='option']")).filter((row) => !row.hidden).every((row) => {
        const box = row.getBoundingClientRect()
        const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
        return box.bottom <= window.innerHeight && row.contains(hit)
      })
    JS
    expect(reachable).to be(true)
  end

  it "still opens in the modal when the pointer rests on the button before the click" do
    sign_in_as(owner)
    visit member_groups_path

    find("[data-test='groups-new']").hover
    # The prefetch has started once the link points at the modal frame.
    expect(page).to have_css("[data-test='groups-new'][data-turbo-frame='modal']")
    find("[data-test='groups-new']").click

    within("dialog[data-test='member-modal'][open]") { expect(page).to have_css("[data-test='group-form']") }
    expect(page).to have_current_path(member_groups_path)
  end
end
