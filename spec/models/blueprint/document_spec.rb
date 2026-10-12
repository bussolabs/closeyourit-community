# frozen_string_literal: true

require "rails_helper"

# CYRA-1071 — the app map a repository keeps in blueprint.json. The page that shows it and the spec
# that guards this repository's own map read it through the same parser.
RSpec.describe Blueprint::Document do
  def node(id, level:, parent:, kind: "area", files: [])
    { "id" => id, "name" => id.humanize, "level" => level, "parent" => parent, "kind" => kind,
      "summary" => "About #{id}.", "files" => files }
  end

  def raw(nodes:, edges: [])
    JSON.generate("version" => 1, "name" => "App", "nodes" => nodes, "edges" => edges)
  end

  let(:valid_nodes) do
    [ node("app", level: 0, parent: nil, kind: "system"),
      node("billing", level: 1, parent: "app"),
      node("checkout", level: 2, parent: "billing", kind: "flow"),
      node("pay", level: 3, parent: "checkout", kind: "step", files: [ "app/services/pay.rb" ]) ]
  end

  it "reads nodes and edges from a valid map" do
    doc = described_class.parse(raw(nodes: valid_nodes, edges: [ { "from" => "checkout", "to" => "pay" } ]))

    expect(doc.nodes.map { _1["id"] }).to eq(%w[app billing checkout pay])
    expect(doc.edges.size).to eq(1)
    expect(doc.files).to eq([ "app/services/pay.rb" ])
  end

  it "counts nodes by kind" do
    doc = described_class.parse(raw(nodes: valid_nodes))

    expect(doc.count("flow")).to eq(1)
    expect(doc.count("data")).to eq(0)
  end

  {
    "text that is not JSON" => -> { "{ nope" },
    "a map without nodes" => -> { JSON.generate("edges" => []) },
    "a duplicate id" => -> { raw(nodes: valid_nodes + [ node("pay", level: 1, parent: "app") ]) },
    "an unknown parent" => -> { raw(nodes: valid_nodes + [ node("x", level: 1, parent: "ghost") ]) },
    "a level that does not follow the parent" => -> { raw(nodes: valid_nodes + [ node("x", level: 3, parent: "app") ]) },
    "an unknown kind" => -> { raw(nodes: valid_nodes + [ node("x", level: 1, parent: "app", kind: "widget") ]) },
    "an edge to a missing node" => -> { raw(nodes: valid_nodes, edges: [ { "from" => "pay", "to" => "ghost" } ]) }
  }.each do |problem, broken|
    it "rejects #{problem}" do
      expect { described_class.parse(instance_exec(&broken)) }.to raise_error(Blueprint::Document::Invalid)
    end
  end
end
