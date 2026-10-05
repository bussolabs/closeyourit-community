# frozen_string_literal: true

require "rails_helper"

# DESIGN.md A2, F1 and H1: no shadows, every button from Ui::ButtonComponent, never a native select.
#
# Many views broke these rules before the rules were written down. The files listed below are the
# ones that did on 2026-10-01: they are fixed when their page is rebuilt. The lists can only shrink:
# a new file that breaks a rule fails here, and a listed file that no longer breaks it must leave the
# list, so the exception never outlives the problem.
RSpec.describe "Design system guards" do
  SOURCES = (Dir[Rails.root.join("app/views/**/*.erb")] +
             Dir[Rails.root.join("app/components/**/*.{erb,rb}")]).sort.freeze

  # Arbitrary values too: an inset `shadow-[…]` is a colored side stripe, forbidden by A17.
  SHADOW = /(?<![\w-])(?:[a-z0-9-]+:)*shadow-(?:sm|md|lg|xl|2xl|inner|\[)/
  NATIVE_SELECT = /<select\s|\bselect_tag\b|\bcollection_select\b|\bgrouped_collection_select\b|\b(?:f|form)\.select\b|\btime_zone_select\b/
  HAND_WRITTEN_BUTTON = /<button\s|\bbutton_to\b|\bbutton_tag\b|\b(?:f|form)\.(?:submit|button)\b/

  # R1: the development sign-in prefill is the one native select allowed for good.
  NATIVE_SELECT_ALLOWED = %w[app/views/auth/sessions/new.html.erb].freeze

  SHADOW_LEGACY = %w[
    app/views/member/home/approvals/_board_row.html.erb
    app/views/member/knowledge/pages/_form.html.erb
    app/views/member/monitoring/error_groups/_assignee_menu.html.erb
    app/views/member/monitoring/server_tokens/index.html.erb
    app/views/member/monitoring/servers/_manage_menu.html.erb
    app/views/member/tickets/_question.html.erb
  ].freeze

  NATIVE_SELECT_LEGACY = %w[
    app/views/member/alerting_rules/_form.html.erb
    app/views/member/datasets/_column_row.html.erb
    app/views/member/monitoring/monitors/_announcement_form.html.erb
    app/views/member/monitoring/monitors/_incident_manage_modal.html.erb
    app/views/member/monitoring/monitors/_incidents.html.erb
    app/views/member/shared_secrets/_cell.html.erb
    app/views/member/tickets/_compose_panel.html.erb
  ].freeze

  HAND_WRITTEN_BUTTON_LEGACY = %w[
    app/views/cli/authorizations/show.html.erb
    app/views/home/_not_now.html.erb
    app/views/layouts/account.html.erb
    app/views/layouts/application.html.erb
    app/views/layouts/member.html.erb
    app/views/layouts/valhalla.html.erb
    app/views/member/_bottom_nav.html.erb
    app/views/member/_global_search_dialog.html.erb
    app/views/member/_keyboard_help.html.erb
    app/views/member/_nav_account.html.erb
    app/views/member/_nav_group.html.erb
    app/views/member/_nav_sidebar.html.erb
    app/views/member/_topbar.html.erb
    app/views/member/agents/compare.html.erb
    app/views/member/agents/tokens/index.html.erb
    app/views/member/alerting_notifications/_notification.html.erb
    app/views/member/alerting_notifications/preview.html.erb
    app/views/member/alerting_preferences/_event_matrix.html.erb
    app/views/member/assistant_conversations/_panel.html.erb
    app/views/member/assistant_conversations/_proposal.html.erb
    app/views/member/assistant_conversations/_proposal_form.html.erb
    app/views/member/assistant_conversations/_proposals.html.erb
    app/views/member/assistant_conversations/_suggestions.html.erb
    app/views/member/chat_conversations/_header.html.erb
    app/views/member/chat_conversations/_message.html.erb
    app/views/member/datasets/_column_row.html.erb
    app/views/member/datasets/_form.html.erb
    app/views/member/datasets/show.html.erb
    app/views/member/datasets/trainings/show.html.erb
    app/views/member/guides/analytics.html.erb
    app/views/member/guides/replays.html.erb
    app/views/member/home/approvals/_board.html.erb
    app/views/member/home/approvals/_board_row.html.erb
    app/views/member/ideas/_case.html.erb
    app/views/member/ideas/_comment.html.erb
    app/views/member/ideas/_linked_idea.html.erb
    app/views/member/ideas/_vote_button.html.erb
    app/views/member/ideas/show.html.erb
    app/views/member/integrations/index.html.erb
    app/views/member/knowledge/pages/_attachments.html.erb
    app/views/member/knowledge/pages/_specs_panel.html.erb
    app/views/member/knowledge/pages/ask.html.erb
    app/views/member/members/index.html.erb
    app/views/member/monitoring/_bulk_triage_bar.html.erb
    app/views/member/monitoring/analytics/_share.html.erb
    app/views/member/monitoring/analytics/_toolbar.html.erb
    app/views/member/monitoring/analytics/show.html.erb
    app/views/member/monitoring/error_groups/_assignee_menu.html.erb
    app/views/member/monitoring/error_groups/_header.html.erb
    app/views/member/monitoring/error_groups/_release.html.erb
    app/views/member/monitoring/error_groups/_side_extras.html.erb
    app/views/member/monitoring/error_groups/_triage_ai.html.erb
    app/views/member/monitoring/error_groups/merges/preview.html.erb
    app/views/member/monitoring/log_entries/_links_panel.html.erb
    app/views/member/monitoring/metric_groups/_triage_ai.html.erb
    app/views/member/monitoring/monitors/_announcement_form.html.erb
    app/views/member/monitoring/monitors/_incident_manage_modal.html.erb
    app/views/member/monitoring/monitors/_incident_timeline.html.erb
    app/views/member/monitoring/monitors/_incidents.html.erb
    app/views/member/monitoring/seo/show.html.erb
    app/views/member/monitoring/seo_sites/_site.html.erb
    app/views/member/monitoring/server_tokens/index.html.erb
    app/views/member/monitoring/servers/_actions.html.erb
    app/views/member/monitoring/servers/_manage_menu.html.erb
    app/views/member/monitoring/shared/_public_link.html.erb
    app/views/member/monitoring/vulnerabilities/show.html.erb
    app/views/member/personal_secret_versions/index.html.erb
    app/views/member/personal_secrets/index.html.erb
    app/views/member/product/features/cells/_form.html.erb
    app/views/member/project_documents/edit.html.erb
    app/views/member/project_environments/index.html.erb
    app/views/member/project_github/_danger_zone.html.erb
    app/views/member/project_secret_assets/versions.html.erb
    app/views/member/project_secret_versions/index.html.erb
    app/views/member/project_secrets/_cell_menu.html.erb
    app/views/member/project_secrets/_cell_variable.html.erb
    app/views/member/project_settings/_danger_zone.html.erb
    app/views/member/project_settings/_token_reveal.html.erb
    app/views/member/project_settings/_tokens_section.html.erb
    app/views/member/projects/_environment_capability_control.html.erb
    app/views/member/secrets/_usage_snippet.html.erb
    app/views/member/service/accounts/show.html.erb
    app/views/member/shared/_color_field.html.erb
    app/views/member/shared/_icon_field.html.erb
    app/views/member/shared_secret_assets/index.html.erb
    app/views/member/shared_secret_assets/versions.html.erb
    app/views/member/shared_secrets/_cell.html.erb
    app/views/member/shared_secrets/_new_row.html.erb
    app/views/member/shared_secrets/_row.html.erb
    app/views/member/tickets/_agent_eligibility_panel.html.erb
    app/views/member/tickets/_assignee_picker.html.erb
    app/views/member/tickets/_attachments.html.erb
    app/views/member/tickets/_comment.html.erb
    app/views/member/tickets/_condition_fields.html.erb
    app/views/member/tickets/_dependencies.html.erb
    app/views/member/tickets/_details_status.html.erb
    app/views/member/tickets/_form_scenarios.html.erb
    app/views/member/tickets/_links.html.erb
    app/views/member/tickets/_page_footer.html.erb
    app/views/member/tickets/_question.html.erb
    app/views/member/tickets/_question_answer_form.html.erb
    app/views/member/tickets/_reviewer_picker.html.erb
    app/views/member/tickets/_scenario_fields.html.erb
    app/views/member/tickets/_technical_analysis.html.erb
    app/views/member/tickets/_vote_button.html.erb
    app/views/member/tickets/ask.html.erb
    app/views/member/tickets/comparison.html.erb
    app/views/member/todo_lists/items/_item.html.erb
    app/views/member/vault/consolidations/show.html.erb
    app/views/member/workload/actions/_details_panel.html.erb
    app/views/member/workload/actions/show.html.erb
    app/views/shared/confirmation_required.html.erb
    app/views/shared/organization_suspended.html.erb
    app/views/valhalla/accounts/edit.html.erb
    app/views/website/access_requests/new.html.erb
    app/views/website/analytics/password.html.erb
  ].freeze

  # A row-menu entry styled with Ui::RowMenuComponent.item_class is the design-system way to write
  # a menu item (see the component), so its button_to does not count as a hand-written button.
  ROW_MENU_ITEM = /<%=?(?:(?!%>).)*RowMenuComponent\.item_class(?:(?!%>).)*%>/m

  def offenders(pattern, skip: [], ignore: nil)
    SOURCES.filter_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if skip.any? { |prefix| relative.start_with?(prefix) }

      source = File.read(path)
      source = source.gsub(ignore, "") if ignore
      relative if source.match?(pattern)
    end
  end

  it "finds the files to check" do
    expect(SOURCES.size).to be > 500
  end

  describe "shadows (A2)" do
    let(:found) { offenders(SHADOW) }

    it "no new file uses a shadow" do
      expect(found - SHADOW_LEGACY).to be_empty
    end

    it "a legacy file that dropped its shadow leaves the list" do
      expect(SHADOW_LEGACY - found).to be_empty
    end
  end

  describe "native selects (H1)" do
    let(:found) { offenders(NATIVE_SELECT, skip: %w[app/components/ui/select_component]) }

    it "no new file renders a native select" do
      expect(found - NATIVE_SELECT_LEGACY - NATIVE_SELECT_ALLOWED).to be_empty
    end

    it "a legacy file that dropped its native select leaves the list" do
      expect(NATIVE_SELECT_LEGACY - found).to be_empty
    end
  end

  describe "hand-written buttons (F1)" do
    let(:found) { offenders(HAND_WRITTEN_BUTTON, skip: %w[app/components/], ignore: ROW_MENU_ITEM) }

    it "no new view writes a button by hand" do
      expect(found - HAND_WRITTEN_BUTTON_LEGACY).to be_empty
    end

    it "a legacy view that moved to Ui::ButtonComponent leaves the list" do
      expect(HAND_WRITTEN_BUTTON_LEGACY - found).to be_empty
    end
  end
end
