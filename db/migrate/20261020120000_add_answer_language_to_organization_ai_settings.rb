# frozen_string_literal: true

# The language every AI answer is written in, per organization; empty follows each person's
# interface language (CYRA-1083).
class AddAnswerLanguageToOrganizationAiSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :organization_ai_settings, :answer_language, :string
  end
end
