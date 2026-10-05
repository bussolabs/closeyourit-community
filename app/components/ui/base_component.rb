# frozen_string_literal: true

module Ui
  # Base dei componenti del design system. Fornisce il merge non distruttivo di
  # class/data/options del caller (vedi closeyourit-design-system/design.md §Convenzioni).
  class BaseComponent < ViewComponent::Base
    private

    # Unisce le classi del componente con quelle passate dal caller, aggiunge il
    # data-test e preserva le altre html options (data-controller, aria, ecc.).
    def merge_options(base_class:, test_id: nil, options: {})
      opts = options.dup
      opts[:class] = [ base_class, opts[:class] ].compact.join(" ").strip
      opts[:data] = (opts[:data] || {}).merge(test: test_id) if test_id
      opts
    end
  end
end
