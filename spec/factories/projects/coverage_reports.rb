# frozen_string_literal: true

FactoryBot.define do
  factory :coverage_report, class: "Projects::CoverageReport" do
    association :project
    branch { "main" }
    sha { "abc1234" }
    captured_at { Time.current }
    line_covered_percent { 98.5 }
    branch_covered_percent { 90.1 }
    files_count { 1 }
    never_loaded_count { 0 }
    payload { { "files" => [], "uncovered_branches" => [], "run" => {} } }
  end
end
