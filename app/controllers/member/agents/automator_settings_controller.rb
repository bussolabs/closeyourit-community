# frozen_string_literal: true

module Member
  module Agents
    # Who works and who reviews for the whole organization (CYAU-227). Every machine without a choice of
    # its own follows it; machines with their own choice are listed so nobody wonders why they differ.
    # Administration like the skill bundle page: behind agents.manage, reached from the machines list.
    class AutomatorSettingsController < Member::BaseController
      before_action -> { require_permission!("agents.manage") }

      def show
        load_page
      end

      def update
        @setting = current_organization.automator_setting || current_organization.build_automator_setting
        @setting.assign_attributes(work_engine: params[:work_engine], reviewer: params[:reviewer], opencode_model: params[:opencode_model])
        return redirect_to(member_agents_automator_setting_path, notice: t("member.automator_settings.saved")) if @setting.save

        # A rejected choice is never written: the page shows the choice still in force.
        @setting = ::Agents::AutomatorSetting.find_by(organization: current_organization) || ::Agents::AutomatorSetting.new
        load_page
        @error = t("member.automator_settings.invalid")
        render :show, status: :unprocessable_content
      end

      private

      def load_page
        @setting ||= ::Agents::AutomatorSetting.for(current_organization)
        hosts = current_organization.agent_hosts.order(:hostname).to_a
        @own_choice_hosts = hosts.reject(&:follows_organization?)
        @following_count = hosts.size - @own_choice_hosts.size
        # CYAU-228 — OpenCode cannot review without the organization's OpenRouter key: say so where it is chosen.
        uses_opencode = @setting.reviewer == "opencode" || hosts.any? { |host| host.effective_reviewer == "opencode" }
        @openrouter_missing = uses_opencode && current_organization.openrouter_credential.nil?
      end
    end
  end
end
