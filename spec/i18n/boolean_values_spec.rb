# frozen_string_literal: true

require "rails_helper"

# O14 — YAML reads a bare `off`, `on`, `yes` or `no` as true/false, and the page then shows "false"
# where a word was meant. Only the number-format settings are real booleans.
RSpec.describe "Translation values that YAML turned into booleans" do
  def boolean_leaves(node, path)
    return node.flat_map { |key, value| boolean_leaves(value, [ *path, key ]) } if node.is_a?(Hash)

    [ true, false ].include?(node) ? [ path.join(".") ] : []
  end

  it "finds none outside the number formats" do
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    offenders = I18n.backend.send(:translations).slice(:en, :it).flat_map { |locale, tree| boolean_leaves(tree, [ locale ]) }

    expect(offenders.reject { |key| key.match?(/\.number\./) }).to eq([])
  end
end
