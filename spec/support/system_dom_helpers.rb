# frozen_string_literal: true

# Selettori system spec SOLO via data-test (rules/rails/testing.md).
module SystemDomHelpers
  def click_on_test(tag) = find("[data-test='#{tag}']").click
  def fill_test(tag, with:) = find("[data-test='#{tag}']").set(with)
  def expect_test(tag) = expect(page).to have_css("[data-test='#{tag}']")
  def within_test(tag, &) = within("[data-test='#{tag}']", &)
end

RSpec.configure do |config|
  config.include SystemDomHelpers, type: :system
end
