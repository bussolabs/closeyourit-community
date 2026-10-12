# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"

RSpec.describe "bin/check-commit" do
  let(:script) { File.expand_path("../../bin/check-commit", __dir__) }

  around do |example|
    Dir.mktmpdir("check-commit") do |directory|
      @repo = directory
      sh("git", "init", "-q")
      sh("git", "config", "user.email", "spec@example.com")
      sh("git", "config", "user.name", "Spec")
      write("db/schema.rb", %(create_table "tickets" do |t|\nend\n))
      sh("git", "add", ".")
      sh("git", "commit", "-qm", "base")
      example.run
    end
  end

  def sh(*command)
    output, status = Open3.capture2e(*command, chdir: @repo)
    raise "#{command.join(' ')}: #{output}" unless status.success?
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
    File.write(File.join(@repo, path), content)
  end

  def stage(path, content)
    write(path, content)
    sh("git", "add", path)
  end

  def check
    Open3.capture2e(script, chdir: @repo)
  end

  it "blocks a staged file that uses a constant defined only in an untracked file" do
    write("app/services/crashes/metadata.rb", "module Crashes\n  class Metadata; end\nend\n")
    stage("app/services/upload.rb", "Crashes::Metadata.new\n")

    output, status = check

    expect(status.exitstatus).to eq(1)
    expect(output).to include("app/services/upload.rb uses app/services/crashes/metadata.rb")
  end

  it "blocks the short constant name only inside the same namespace directory" do
    write("app/services/crashes/metadata.rb", "")
    stage("app/services/crashes/multipart.rb", "Metadata.new\n")
    stage("app/services/other.rb", "Metadata.new\n")

    output, status = check

    expect(status.exitstatus).to eq(1)
    expect(output).to include("app/services/crashes/multipart.rb uses")
    expect(output).not_to include("app/services/other.rb uses")
  end

  it "blocks a partial rendered from a staged view while it is untracked" do
    write("app/views/member/tickets/_event_group.html.erb", "")
    stage("app/views/member/tickets/show.html.erb", %(<%= render "event_group" %>\n))

    expect(check.last.exitstatus).to eq(1)
  end

  it "passes when the referenced file is staged too" do
    stage("app/services/crashes/metadata.rb", "")
    stage("app/services/upload.rb", "Crashes::Metadata.new\n")

    expect(check.last).to be_success
  end

  it "ignores untracked files that no staged change uses, such as concurrent work" do
    write("app/services/crashes/metadata.rb", "")
    stage("app/services/upload.rb", "Upload.call\n")

    expect(check.last).to be_success
  end

  it "blocks a schema change with no staged migration" do
    stage("db/schema.rb", %(create_table "tickets" do |t|\n  t.string :title\nend\n))

    output, status = check

    expect(status.exitstatus).to eq(1)
    expect(output).to include("no staged migration")
  end

  it "blocks schema tables that no staged migration mentions" do
    stage("db/migrate/20261007000000_add_title.rb", "add_column :tickets, :title, :string\n")
    stage("db/schema.rb", %(create_table "tickets" do |t|\nend\ncreate_table "legacy_agents" do |t|\nend\n))

    output, status = check

    expect(status.exitstatus).to eq(1)
    expect(output).to include("adds table legacy_agents")
  end

  it "passes when the staged migration creates the new table" do
    stage("db/migrate/20261007000000_create_notes.rb", "create_table :notes\n")
    stage("db/schema.rb", %(create_table "tickets" do |t|\nend\ncreate_table "notes" do |t|\nend\n))

    expect(check.last).to be_success
  end

  describe "blueprint.json (CYRA-1071)" do
    def map_with(*nodes)
      JSON.generate("nodes" => [ { "id" => "rails", "name" => "App", "level" => 0, "files" => [ "app/**" ] } ] + nodes)
    end

    before do
      stage("blueprint.json", map_with(
        { "id" => "area_errors", "name" => "Errors", "level" => 1, "files" => [ "app/services/errors/**" ] },
        { "id" => "err_record", "name" => "Record and group", "level" => 2, "files" => [ "app/services/errors/record.rb" ] }
      ))
      sh("git", "commit", "-qm", "map")
    end

    it "warns about the deepest bubble whose files changed without the map, and still lets the commit through" do
      stage("app/services/errors/record.rb", "class Record; end\n")

      output, status = check

      expect(status).to be_success
      expect(output).to include("blueprint.json not updated").and include("Record and group")
      expect(output).not_to include("Errors,")
    end

    it "stays quiet when the map changes in the same commit" do
      stage("app/services/errors/record.rb", "class Record; end\n")
      stage("blueprint.json", map_with({ "id" => "area_errors", "name" => "Errors", "level" => 1, "files" => [ "app/services/errors/**" ] }))

      expect(check.first).not_to include("blueprint.json not updated")
    end

    it "stays quiet for files that only the whole-app bubble covers" do
      stage("app/models/note.rb", "class Note; end\n")

      expect(check.first).not_to include("blueprint.json not updated")
    end
  end
end
