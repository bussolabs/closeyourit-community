# frozen_string_literal: true

module Ui
  # Campo input DS: label (con marker `*` se required), input, errore/hint.
  # Marker obbligatori = asterisco rosso; mai suffisso "(opzionale)" (rules/design-system.md).
  class InputComponent < BaseComponent
    FIELD = "w-full h-[34px] px-3 rounded-md border text-[13px] text-zinc-900 dark:text-zinc-100 " \
            "placeholder:text-gray-400 dark:placeholder:text-zinc-500 focus:outline-none focus-visible:ring-2"

    def initialize(name:, label: nil, type: "text", value: nil, placeholder: nil,
                   required: false, error: nil, hint: nil, wrapper_class: nil, test_id: nil, **options)
      @name = name
      @label = label
      @type = type
      @value = value
      @placeholder = placeholder
      @required = required
      @error = error
      @hint = hint
      @wrapper_class = wrapper_class
      @test_id = test_id
      @options = options
    end

    private

    def field_id = @options.fetch(:id, @name)

    def field_klass
      border = if @error
        "border-red-400 focus:border-red-500 focus-visible:ring-red-500"
      else
        "border-stone-200 dark:border-zinc-800 focus:border-indigo-600 dark:focus:border-indigo-400 focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400"
      end
      field = @type == "textarea" ? FIELD.sub("h-[34px]", "min-h-24 py-2 resize-y") : FIELD
      [ field, border ].join(" ")
    end

    def input_options
      opts = merge_options(base_class: field_klass, test_id: @test_id, options: @options)
      aria = if @error
        { "aria-invalid": "true", "aria-describedby": "#{field_id}_error" }
      elsif @hint
        { "aria-describedby": "#{field_id}_hint" }
      else
        {}
      end
      opts.merge(
        type: @type, name: @name, id: field_id, value: @value,
        placeholder: @placeholder, required: @required,
        **aria
      )
    end
  end
end
