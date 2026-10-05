# frozen_string_literal: true

module Telegram
  # Risolve IL progetto per un comando Telegram, scoped alla visibilità dell'account (anti-BOLA).
  #  - key presente → cerca quel progetto tra i visibili di tutte le org dell'account (0 → not_found,
  #    >1 org con la stessa key visibile → ambiguous).
  #  - key assente → usa il progetto "attivo" (account.telegram_project_id), ri-verificando che sia
  #    ANCORA visibile; stale/assente → none.
  # Ritorna Result.ok(project) o Result.err(AppError con messaggio già localizzato per il chiamante).
  class ResolveProject < ApplicationService
    include Telegram::VisibleProjects

    def initialize(account:, key: nil)
      @account = account
      @key = key.to_s.strip
    end

    def call
      @key.present? ? by_key : active
    end

    private

    def by_key
      normalized = @key.upcase
      matches = candidate_organizations(@account).filter_map do |org|
        project_scope(@account, org).find_by(key: normalized)
      end.uniq(&:id)

      return err(:project_not_found, "R404-TELEGRAM-002", :not_found, key: normalized) if matches.empty?
      return err(:project_ambiguous, "R409-TELEGRAM-001", :conflict, key: normalized) if matches.size > 1

      Result.ok(matches.first)
    end

    def active
      id = @account.telegram_project_id
      return err(:project_none, "R404-TELEGRAM-003", :not_found) if id.blank?

      project = Projects::Project.find_by(id: id)
      return err(:project_none, "R404-TELEGRAM-003", :not_found) if project.nil? || !visible?(project)

      Result.ok(project)
    end

    def visible?(project)
      candidate_organizations(@account).exists?(id: project.organization_id) &&
        project_scope(@account, project.organization).exists?(id: project.id)
    end

    def err(key, code, status, **args)
      Result.err(AppError.new(t(key, **args), code: code, status: status))
    end

    def t(key, **args)
      I18n.t("telegram.errors.#{key}", locale: @account.effective_locale, **args)
    end
  end
end
