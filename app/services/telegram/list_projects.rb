# frozen_string_literal: true

module Telegram
  # /progetti: elenca i progetti visibili dell'account (cross-org) con la loro chiave, così l'utente
  # sa cosa passare a /progetto CHIAVE o /nuovo-ticket CHIAVE. Anti-BOLA: solo i progetti visibili.
  class ListProjects < ApplicationService
    include Telegram::Respondable
    include Telegram::VisibleProjects

    LIMIT = 30

    def initialize(account:, chat_id:)
      @account = account
      @chat_id = chat_id
    end

    def call
      projects = all_visible_projects(@account)
      if projects.empty?
        reply("projects.empty")
      else
        lines = projects.first(LIMIT).map { |project| t("projects.item", key: project.key, name: project.name) }
        reply("projects.list", list: lines.join("\n"))
      end
      Result.ok(:listed)
    end
  end
end
