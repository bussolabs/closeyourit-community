# frozen_string_literal: true

module Todos
  module Shares
    # Imposta l'insieme dei destinatari (sola lettura) di una lista: diff add/remove verso
    # account_ids. Valida PRIMA di mutare — se un destinatario non è membro dell'org o è il
    # proprietario, niente viene modificato e si ritorna err (anti-leak cross-tenant). Result pattern.
    class SetShares < ApplicationService
      def initialize(list:, account_ids:)
        @list = list
        @desired = Array(account_ids).map { |id| id.to_s.strip }.reject(&:blank?).uniq
      end

      def call
        existing = @list.shares.pluck(:account_id).map(&:to_s)
        new_shares = (@desired - existing).map { |account_id| @list.shares.build(account_id: account_id) }

        invalid = new_shares.reject(&:valid?)
        if invalid.any?
          return Result.err(AppError.new(I18n.t("todos.shares.errors.invalid"),
                                         code: "R422-TODOSHARE-001", details: invalid.first.errors.to_hash))
        end

        ActiveRecord::Base.transaction do
          @list.shares.where.not(account_id: @desired).destroy_all
          new_shares.each(&:save!)
        end
        Result.ok(@list)
      end
    end
  end
end
