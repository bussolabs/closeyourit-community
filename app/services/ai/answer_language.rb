# frozen_string_literal: true

module Ai
  # The language every AI answer is written in (CYRA-1083): the organization's choice, otherwise the
  # interface language of whoever is asking. Ai::Llm::Client adds it to every system prompt, so the
  # prompts themselves no longer decide it.
  module AnswerLanguage
    NAMES = { "en" => "English", "it" => "Italian" }.freeze

    def self.code(organization = Current.organization)
      organization&.ai_setting&.answer_language.presence || I18n.locale.to_s
    end

    def self.instruction(organization = Current.organization)
      name = NAMES.fetch(code(organization)) { NAMES.fetch(I18n.default_locale.to_s) }
      "Write your answer, and every text you return, in #{name}, whatever the language of the question, " \
        "of the data or of these instructions."
    end
  end
end
