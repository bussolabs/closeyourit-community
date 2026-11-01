# frozen_string_literal: true

module Cli
  module V1
    module Wikitech
      # `cyi wikitech ask` (CYRA-1131): the answer written only from the organization's cards.
      class AsksController < Cli::V1::BaseController
        def create
          result = ::Wikitech::Ask.call(scope: Current.organization.wikitech_entries, question: params[:question])
          return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

          answer = result.value
          render_ok({ answer: answer.answer, insufficient: answer.insufficient,
                      entries: WikitechEntrySummarySerializer.new(answer.entries).as_json })
        end
      end
    end
  end
end
