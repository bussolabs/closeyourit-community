# frozen_string_literal: true

module Ui
  # Indicatore compatto dello stato repository GitHub di un progetto.
  # La forma affianca al marchio GitHub un check o un minus, così lo stato non dipende
  # dal solo colore. Il testo accessibile e il tooltip arrivano da i18n.
  class GithubStatusComponent < BaseComponent
    SIZES = {
      sm: { github: "text-[14px]", state: "text-[7px]" },
      lg: { github: "text-[16px]", state: "text-[8px]" }
    }.freeze

    def initialize(connected:, size: :sm, test_id: nil, **options)
      @connected = connected
      @size = size.to_sym
      @test_id = test_id
      @options = options

      raise ArgumentError, "size sconosciuta: #{@size}" unless SIZES.key?(@size)
    end

    private

    def html_options
      merge_options(
        base_class: "relative inline-flex items-center #{status_color}",
        test_id: @test_id,
        options: status_options
      )
    end

    def status_options
      @options.deep_dup.tap do |options|
        options[:role] ||= "img"
        options[:aria] = (options[:aria] || {}).merge(label: status_label)
        options[:title] ||= status_label
      end
    end

    def github_size = SIZES.fetch(@size).fetch(:github)
    def state_size = SIZES.fetch(@size).fetch(:state)
    def state_icon = @connected ? "circle-check" : "circle-minus"
    def status_color = @connected ? "text-zinc-900 dark:text-zinc-100" : "text-gray-300 dark:text-zinc-600"
    def state_color = @connected ? "text-emerald-600 dark:text-emerald-400" : "text-gray-400 dark:text-zinc-500"
    def status_label = t(@connected ? "ui.github_status.connected" : "ui.github_status.not_connected")
  end
end
