# frozen_string_literal: true

module Alerting
  # A click on one of the three buttons of an alert in Slack. Every click redoes the site's checks: linked
  # Slack person, still in the organization, allowed; a refusal is a private reply. CYRA-1156
  class SlackAction < ApplicationService
    ACTIONS = %w[alert_claim alert_mute alert_ticket].freeze

    def initialize(team_id:, user_id:, channel:, ts:, action:)
      @team_id = team_id.to_s
      @user_id = user_id.to_s
      @channel = channel.to_s
      @ts = ts.to_s
      @action = action.to_s
    end

    def call
      return Result.ok(:ignored) unless ACTIONS.include?(@action)

      @message = SlackMessage.find_by(slack_channel: @channel, slack_ts: @ts)
      return Result.ok(:ignored) if @message.nil?

      @account = linked_account
      return refuse("link_first") if @account.nil?
      return refuse("not_member") unless @account.member_of_organization?(@message.organization_id)

      # The row lock turns two quick clicks into one action and one change of the message.
      @message.with_lock { perform }
    end

    private

    def perform
      return refuse("recovered") if @message.status_recovered?

      case @action
      when "alert_claim" then claim
      when "alert_mute" then mute
      else open_ticket
      end
    end

    def linked_account
      link = Coworkers::SlackLink.find_by(slack_team_id: @team_id, slack_user_id: @user_id)
      link.account if link && link.organization_id == @message.organization_id
    end

    # Only errors have an assignee in CloseYourIt; for any other alert taking it stays on the message.
    def claim
      return Result.ok(:unchanged) if @message.claimed_by_id == @account.id

      subject = @message.subject
      if subject.is_a?(Errors::Group)
        return refuse("forbidden") unless resolver.can?("errors.assign", scope: subject.project)

        Errors::Assign.call(group: subject, assignee_id: @account.id)
        Errors::Broadcast.refresh_group(subject)
      elsif !project_visible?
        return refuse("forbidden")
      end
      @message.change!(claimed_by: @account, claimed_at: Time.current)
      Result.ok(:claimed)
    end

    # The whole rule goes quiet, as from the rules page: the message names the rule and the end.
    def mute
      return Result.ok(:unchanged) if @message.muted?

      rule = mutable_rule
      return refuse("rule_gone") if rule.nil?
      return refuse("forbidden") unless resolver.can?("alerts.manage")

      rule.with_lock { rule.update!(muted_until: Time.current + SlackMessage::MUTE_FOR) unless rule.muted? }
      @message.change!(muted_by: @account, muted_until: rule.muted_until)
      Result.ok(:muted)
    end

    def open_ticket
      return Result.ok(:unchanged) if @message.ticket_id.present?

      entry = SlackTickets.for(@message.subject_type)
      subject = @message.subject
      return refuse("no_ticket") if entry.nil? || subject.nil?
      return refuse("forbidden") unless resolver.can?(entry.permission, scope: subject.project)

      ticket = SlackTickets.ticket_of(entry.promote.call(subject, @account), subject)
      return refuse("ticket_failed") if ticket.nil?

      @message.change!(ticket: ticket, ticket_opened_by: @account)
      Result.ok(:ticket)
    end

    # Same lookup as the rules page: a measurement rule of a project you cannot see does not exist.
    def mutable_rule
      return nil if @message.rule_id.nil?

      @message.organization.alerting_rules.with_visible_measurements(visible.projects).find_by(id: @message.rule_id)
    end

    def project_visible?
      @message.project_id.nil? || visible.projects.exists?(id: @message.project_id)
    end

    def resolver
      @resolver ||= Authorization::Resolver.new(account: @account, organization: @message.organization)
    end

    def visible
      @visible ||= Authorization::VisibleScope.new(account: @account, organization: @message.organization)
    end

    def refuse(key)
      locale = @account&.effective_locale || I18n.default_locale
      text = I18n.with_locale(locale) do
        key == "link_first" ? I18n.t("member.coworkers.slack.link_first") : I18n.t("alerting.slack.refusals.#{key}")
      end
      Coworkers::Slack.post_ephemeral(channel: @channel, user: @user_id, text: text)
      Result.ok(:"refused_#{key}")
    end
  end
end
