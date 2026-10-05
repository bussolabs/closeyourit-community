# frozen_string_literal: true

module Member
  # C60, N5 — a long list of group and project names in a cell shows the first few and "+N";
  # the full list stays on hover and for screen readers, so the row keeps the height of the others.
  module ScopeNamesHelper
    SCOPE_NAMES_SHOWN = 3

    def scope_names_summary(names, separator: " · ")
      return safe_join(names, separator) if names.size <= SCOPE_NAMES_SHOWN

      shown = safe_join(names.first(SCOPE_NAMES_SHOWN), separator)
      more = tag.span("+#{names.size - SCOPE_NAMES_SHOWN}", class: "ml-1 font-mono", "aria-hidden": true)
      rest = tag.span(safe_join([ separator, safe_join(names.drop(SCOPE_NAMES_SHOWN), separator) ]), class: "sr-only")
      tag.span(safe_join([ shown, more, rest ]), title: names.join(separator), data: { test: "scope-names-summary" })
    end
  end
end
