# frozen_string_literal: true

module Cli
  module V1
    module Wikitech
      # `cyi wikitech add` (CYRA-1128): any member of the organization sends a plain-text note.
      # Resending the same text answers 200 with `meta.duplicate` instead of creating it twice.
      class NotesController < Cli::V1::BaseController
        def create
          result = ::Wikitech::SaveNote.call(organization: Current.organization, author: Current.account,
                                             params: note_params)
          return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

          data = WikitechNoteSerializer.new(result.value.note)
          return render_ok(data, meta: { duplicate: true }) if result.value.duplicate

          render_created(data)
        end

        private

        def note_params
          params.permit(:body, :source_label, :source_url, :source_published_at, links: [])
        end
      end
    end
  end
end
