# frozen_string_literal: true

module Cli
  module V1
    module Wikitech
      # `cyi wikitech search` / `show` (CYRA-1131): the organization's cards, same search as the page.
      class EntriesController < Cli::V1::BaseController
        VERIFICATIONS = ::Wikitech::Entry.verifications.keys.freeze

        def index
          scope = Current.organization.wikitech_entries.ordered
          scope = scope.in_category(params[:category]) if params[:category].present?
          scope = scope.where(verification: params[:verification]) if VERIFICATIONS.include?(params[:verification])
          outcome = ::Wikitech::Search.call(scope: scope, query: params[:q])
          records, meta = paginate(outcome.scope)
          meta[:search] = outcome.mode if outcome.mode
          render_ok(WikitechEntrySummarySerializer.new(records), meta: meta)
        end

        def show
          entry = Current.organization.wikitech_entries.includes(sources: :note).find_by(id: params[:id])
          return render_error("R404-WIKITECH-001", I18n.t("wikitech.errors.not_found"), status: :not_found) if entry.nil?

          render_ok(WikitechEntrySerializer.new(entry))
        end
      end
    end
  end
end
