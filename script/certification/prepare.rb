# frozen_string_literal: true

require_relative "runtime"
run_id = Certification::Runtime.boot!
require "pg"

names = [ "closeyourit_test_cert_#{run_id}", "closeyourit_queue_test_cert_#{run_id}" ]
PG.connect(dbname: "postgres") do |connection|
  locked = connection.exec_params("SELECT pg_try_advisory_lock(hashtextextended($1, 0)) AS locked", [ "certification:#{run_id}" ])
  raise "Another process is preparing this certification run" unless locked.first.fetch("locked") == "t"

  existing = connection.exec_params("SELECT datname FROM pg_database WHERE datname = ANY($1::text[])",
                                    [ "{#{names.join(',')}}" ]).map { |row| row.fetch("datname") }
  raise "Certification databases already exist; refusing to reset them" unless existing.empty?
  %w[cache cable].each do |kind|
    raise "Certification SQLite database already exists" if Rails.root.join("storage/test_#{kind}_cert_#{run_id}.sqlite3").exist?
  end

  puts "Preparing new local test databases: #{names.join(', ')}"
  Rails.application.load_tasks
  Rake::Task["db:create"].invoke
  Rake::Task["db:schema:load"].invoke
  # A checkout can contain migrations newer than its committed schema snapshot.
  ActiveRecord.dump_schema_after_migration = false
  Rake::Task["db:migrate"].invoke
  Ops::Partitions::Ensure.call
  puts "Certification databases prepared"
end
