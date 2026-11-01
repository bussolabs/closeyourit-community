# frozen_string_literal: true

module Member
  module Wikitech
    # Wikitech (CYRA-1130): ask a question, browse the cards, open one. Organization-wide external
    # knowledge, so every member reads it; nothing here depends on projects. Models fully qualified
    # (::Wikitech::*) against shadowing by this namespace.
    class EntriesController < Member::BaseController
      permission_not_required "Wikitech holds external tech knowledge of the whole organization: every member " \
                              "reads it and asks questions about it."

      remembers_filters :category, :verification, :q, :sort, only: :index

      SORT_COLUMNS = {
        "name" => "LOWER(wikitech_entries.name)",
        "sources" => :sources_count,
        "stars" => "COALESCE((wikitech_entries.repo_meta->>'stars')::integer, -1)",
        "updated" => :updated_at
      }.freeze

      def index
        all = Current.organization.wikitech_entries
        @counts = { total: all.count, verified: all.verification_verified.count,
                    unconfirmed: all.where.not(repo_url: nil).verification_unconfirmed.count }
        @categories = all.distinct.pluck(Arel.sql("unnest(categories)")).sort
        @pagination = paginate(listed(all))
        @entries = @pagination.records
      end

      def show
        @entry = Current.organization.wikitech_entries.includes(sources: :note).find(params[:id])
      end

      # The answer comes from a worker (202 + request id, polled by the page) like "Ask the knowledge base".
      def ask
        question = params[:question].to_s
        if question.strip.blank?
          return render json: { error: { code: "R422-WIKITECH-004", message: t("wikitech.errors.question_blank") } },
                        status: :unprocessable_content
        end

        enqueue_ai_request!(kind: "wikitech_ask", args: { question: question })
      end

      private

      def listed(scope)
        categories = filter_ids(:category)
        scope = scope.where("wikitech_entries.categories && ARRAY[?]::text[]", categories) if categories.any?
        verifications = filter_ids(:verification) & ::Wikitech::Entry.verifications.keys
        scope = scope.where(verification: verifications) if verifications.any?
        return sorted(scope.ordered, columns: SORT_COLUMNS) if search_q.blank?

        # A search orders by relevance until someone clicks a column header.
        found = ::Wikitech::Search.call(scope: scope.ordered, query: search_q).scope
        params[:sort].present? ? sorted(found, columns: SORT_COLUMNS) : found
      end
    end
  end
end
