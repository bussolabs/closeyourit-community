# frozen_string_literal: true

module Telegram
  # /puck lists the person's Puckies, /puck <name> picks one, /p <text> asks it (CYRA-1018).
  # The run is the same one the web conversation shows; the answer comes back here.
  class AskPuck < ApplicationService
    include Telegram::Respondable

    def initialize(account:, chat_id:, command:, args:)
      @account = account
      @chat_id = chat_id
      @command = command
      @args = args.to_s.strip
    end

    def call
      return choose if @command == "puck"
      return reply_text(t("puck.usage")) && Result.ok(:usage) if @args.blank?

      puck = active_puck
      return reply_text(t("puck.none")) && Result.ok(:no_puck) if puck.nil?

      Coworkers::Start.call(puck: puck, kind: "chat", input: @args, account: @account,
                            channel: "telegram", channel_ref: { "chat_id" => @chat_id.to_s })
      reply_text(t("puck.asked", name: puck.name))
      Result.ok(:asked)
    rescue Coworkers::Start::Busy, Coworkers::Start::OverBudget
      reply_text(t("puck.busy"))
      Result.ok(:busy)
    end

    private

    def puckies
      organizations = @account.memberships.select(:organization_id)
      Coworkers::Puck.where(organization_id: organizations).includes(:organization).order(:name).select do |puck|
        Coworkers.available_to?(account: @account, organization: puck.organization) &&
          Authorization::VisibleScope.new(account: @account, organization: puck.organization).coworker_puckies.exists?(id: puck.id)
      end
    end

    def active_puck
      list = puckies
      list.find { |puck| puck.id == @account.telegram_puck_id } || list.first
    end

    def choose
      list = puckies
      return reply_text(t("puck.none")) && Result.ok(:no_puck) if list.empty?
      return reply_text(t("puck.list", names: list.map(&:name).join(", "))) && Result.ok(:listed) if @args.blank?

      puck = list.find { |candidate| candidate.name.casecmp?(@args) }
      return reply_text(t("puck.unknown", names: list.map(&:name).join(", "))) && Result.ok(:unknown) if puck.nil?

      @account.update!(telegram_puck_id: puck.id)
      reply_text(t("puck.chosen", name: puck.name))
      Result.ok(:chosen)
    end
  end
end
