# frozen_string_literal: true

require "json"
require "pathname"

class CoverageResultsetNormalizer
  def self.call(resultset:, source_root:, destination_root:)
    new(resultset:, source_root:, destination_root:).call
  end

  def initialize(resultset:, source_root:, destination_root:)
    @resultset = Pathname(resultset)
    @source_root = Pathname(source_root).cleanpath.to_s
    @destination_root = Pathname(destination_root).cleanpath.to_s
    raise ArgumentError, "source_root non può essere vuoto" if source_root.empty?
    raise ArgumentError, "destination_root non può essere vuoto" if destination_root.empty?
  end

  def call
    data = JSON.parse(resultset.read)

    data.each_value do |suite|
      coverage = suite.fetch("coverage")
      suite["coverage"] = coverage.to_h do |path, measurements|
        [ normalize(path), measurements ]
      end
    end

    output = resultset.dirname.join("normalized.resultset.json")
    output.write(JSON.generate(data))
    output
  end

  private

  attr_reader :resultset, :source_root, :destination_root

  def normalize(path)
    return path unless path == source_root || path.start_with?("#{source_root}/")

    path.sub(/\A#{Regexp.escape(source_root)}/, destination_root)
  end
end
