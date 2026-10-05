# frozen_string_literal: true

module Ui
  # CYRA-748 — La voce dell'elenco descrittivo: etichetta sopra, valore sotto. È un componente e non
  # uno slot nudo perché il valore può essere composto, e allora l'etichetta deve restare comunque
  # scritta in un modo solo.
  class DescriptionListComponent::Item < BaseComponent
    def initialize(label:, value: nil, span: nil, hint: nil, hint_title: nil, hint_test_id: nil,
                   value_class: DescriptionListComponent::DEFAULT_VALUE_CLASS, test_id: nil, **options)
      @label = label
      @value = value
      @span = span
      @hint = hint
      @hint_title = hint_title
      @hint_test_id = hint_test_id
      @value_class = value_class
      @test_id = test_id
      @options = options
      return if span.nil? || DescriptionListComponent::SPANS.key?(span)

      raise ArgumentError, "span fuori mappa: #{span}"
    end

    private

    def label_class
      @hint.present? ? DescriptionListComponent::LABEL_WITH_HINT : DescriptionListComponent::LABEL
    end

    # Una voce senza larghezza dichiarata e senza classi del chiamante esce come `<div>` nudo: un
    # `class=""` sarebbe markup che nelle pagine attuali non c'è.
    def html_options
      opts = merge_options(base_class: DescriptionListComponent::SPANS[@span].to_s, test_id: @test_id,
                           options: @options)
      opts.delete(:class) if opts[:class].blank?
      opts
    end
  end
end
