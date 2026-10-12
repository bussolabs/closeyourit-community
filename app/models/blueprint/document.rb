# frozen_string_literal: true

module Blueprint
  # The app map a repository keeps in blueprint.json: nodes on levels 0-3 linked to their parent,
  # plus edges between them. Parsing checks the structure only; file globs are checked by the spec
  # of the repository that owns the map (CYRA-1071).
  class Document
    class Invalid < StandardError; end

    KINDS = %w[actor external system area flow page job data step].freeze
    MAX_LEVEL = 3

    attr_reader :name, :nodes, :edges

    def self.parse(raw)
      data = JSON.parse(raw.to_s)
      raise Invalid, "the map has no nodes" unless data.is_a?(Hash) && data["nodes"].is_a?(Array)

      new(name: data["name"].to_s, nodes: data["nodes"], edges: Array(data["edges"]))
    rescue JSON::ParserError => e
      raise Invalid, "the map is not valid JSON: #{e.message.first(120)}"
    end

    def initialize(name:, nodes:, edges:)
      @name = name
      @nodes = nodes
      @edges = edges
      validate!
    end

    def count(kind) = nodes.count { _1["kind"] == kind }

    def files = nodes.flat_map { Array(_1["files"]) }

    def to_h = { "name" => name, "nodes" => nodes, "edges" => edges }

    private

    def validate!
      by_id = {}
      nodes.each do |node|
        id = node["id"].to_s
        raise Invalid, "a node has no id" if id.empty?
        raise Invalid, "duplicate id #{id}" if by_id.key?(id)
        raise Invalid, "#{id} has unknown kind #{node["kind"]}" unless KINDS.include?(node["kind"])

        by_id[id] = node
      end
      nodes.each { check_parent(_1, by_id) }
      edges.each { |edge| check_edge(edge, by_id) }
    end

    def check_parent(node, by_id)
      level = node["level"]
      raise Invalid, "#{node["id"]} has level #{level}" unless level.is_a?(Integer) && level.between?(0, MAX_LEVEL)
      return if node["parent"].nil? && level.zero?

      parent = by_id[node["parent"]]
      raise Invalid, "#{node["id"]} has unknown parent #{node["parent"]}" if parent.nil?
      raise Invalid, "#{node["id"]} must sit one level below #{parent["id"]}" unless level == parent["level"] + 1
    end

    def check_edge(edge, by_id)
      [ edge["from"], edge["to"] ].each do |id|
        raise Invalid, "an edge points to missing node #{id}" unless by_id.key?(id)
      end
    end
  end
end
