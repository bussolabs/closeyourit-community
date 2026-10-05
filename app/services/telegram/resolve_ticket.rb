# frozen_string_literal: true

module Telegram
  # Risolve un ticket dal suo code umano "CHIAVE-NUMERO" (es. DRRA-12), scoped alla visibilità
  # dell'account (anti-BOLA): la chiave deve appartenere a un progetto visibile e il numero esistere
  # dentro quel progetto. Ticket di altra org / progetto non visibile / code malformato → err.
  # Mirror di Cli::V1::BaseController#find_ticket! per il canale Telegram.
  class ResolveTicket < ApplicationService
    include Telegram::VisibleProjects

    CODE = /\A([A-Za-z0-9]{1,4})-(\d+)\z/

    def initialize(account:, code:)
      @account = account
      @code = code.to_s.strip
    end

    def call
      match = CODE.match(@code)
      return err(:ticket_bad_code, "R422-TELEGRAM-007") if match.nil?

      key = match[1].upcase
      number = match[2].to_i
      candidate_organizations(@account).each do |org|
        project = project_scope(@account, org).find_by(key: key)
        next if project.nil?

        ticket = project.tickets.find_by(number: number)
        return Result.ok(ticket) if ticket
      end
      err(:ticket_not_found, "R404-TELEGRAM-005", code: @code)
    end

    private

    def err(key, code, **args)
      Result.err(AppError.new(t(key, **args), code: code, status: :not_found))
    end

    def t(key, **args)
      I18n.t("telegram.errors.#{key}", locale: @account.effective_locale, **args)
    end
  end
end
