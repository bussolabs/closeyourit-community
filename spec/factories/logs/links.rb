# frozen_string_literal: true

FactoryBot.define do
  factory :log_link, class: "Logs::Link" do
    log_entry { association(:log_entry) }
    # invariante: il linkable vive nello stesso progetto del log
    linkable { association(:error_group, project: log_entry.project) }
    created_by { association(:account) }
  end
end
