# frozen_string_literal: true

module Ui
  class TableComponent < BaseComponent
    # CYRA-924 — the four states of a table (DESIGN.md C51): empty, no results, loading, error. The
    # table renders it inside the body, under the headers and across every column, so the toolbar
    # and the headers stay in place.
    class StateComponent < BaseComponent
      KINDS = {
        empty: { icon: "inbox", role: nil },
        no_results: { icon: "search", role: nil },
        loading: { icon: "loader-circle", role: "status" },
        error: { icon: "triangle-alert", role: "alert" }
      }.freeze

      renders_one :action

      def initialize(kind:, title:, body: nil, icon: nil, reset_href: nil, reset_label: nil, test_id: nil)
        raise ArgumentError, "Ui::TableComponent::StateComponent: unknown kind #{kind.inspect}" unless KINDS.key?(kind)

        @kind = kind
        @title = title
        @body = body
        @icon = icon || KINDS.dig(kind, :icon)
        @reset_href = reset_href
        @reset_label = reset_label
        @test_id = test_id
      end

      private

      def wrapper_options
        role = KINDS.dig(@kind, :role)
        { class: "px-6 py-12 text-center", role: role, "aria-live": (role == "status" ? "polite" : nil),
          data: { test: @test_id, "table-state": @kind }.compact }.compact
      end

      def icon_class
        spin = @kind == :loading ? " motion-safe:animate-spin" : ""
        tone = @kind == :error ? "bg-rose-50 dark:bg-rose-500/15 text-rose-600 dark:text-rose-400" : "bg-stone-100 dark:bg-zinc-800 text-gray-400 dark:text-zinc-500"
        [ "inline-flex items-center justify-center w-11 h-11 rounded-full #{tone}", "text-[16px]#{spin}" ]
      end
    end
  end
end
